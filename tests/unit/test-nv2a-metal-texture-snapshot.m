/* Independent CPU-seeded GPU snapshots; no VM/window/application.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "hw/xbox/nv2a/pgraph/metal/texture-snapshot.h"
#import "hw/xbox/nv2a/pgraph/metal/texture-sampler.h"
#include "hw/xbox/nv2a/pgraph/metal/texture-upload-types.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned images, words, compactBytes, rejected;
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "%s\n", error.description.UTF8String);
        abort();
    }
}
static uint32_t value(unsigned face, unsigned level, unsigned z, unsigned y,
                      unsigned x)
{
    static const uint32_t special[] = { 0x80000000, 0x7fc12345, 0x7f800000,
                                        0xff800000 };
    if (!face && !level && !z && !y && x < 4)
        return special[x];
    return 0x3f000000 | face << 20 | level << 16 | z << 12 | y << 8 | x;
}
static uint8_t byte_value(unsigned face, unsigned level, unsigned z, unsigned y,
                          unsigned x)
{
    return (uint8_t)(face * 43 + level * 59 + z * 17 + y * 7 + x * 71);
}
static void append(NSMutableData *data, uint32_t word)
{
    uint8_t bytes[] = { word >> 24, word >> 16, word >> 8, word };
    [data appendBytes:bytes length:4];
}
static void put(NSMutableData *data, unsigned offset, uint32_t word)
{
    uint8_t *bytes = data.mutableBytes;
    bytes[offset] = word >> 24;
    bytes[offset + 1] = word >> 16;
    bytes[offset + 2] = word >> 8;
    bytes[offset + 3] = word;
}
static void run(NV2AMetalCommands *commands, unsigned kind, unsigned width,
                unsigned height, unsigned depth, unsigned levels, BOOL view,
                unsigned compact)
{
    NSError *error = nil;
    static const MTLPixelFormat formats[] = {
        MTLPixelFormatRGBA32Float, MTLPixelFormatRGBA8Unorm,
        MTLPixelFormatRGBA16Float, MTLPixelFormatR32Float,
        MTLPixelFormatRG32Float,   MTLPixelFormatR32Float,
        MTLPixelFormatR32Float,    MTLPixelFormatR32Float,
        MTLPixelFormatR32Float,    MTLPixelFormatB5G6R5Unorm,
        MTLPixelFormatBGR5A1Unorm, MTLPixelFormatBGR5A1Unorm,
        MTLPixelFormatABGR4Unorm,
        MTLPixelFormatRGBA8Snorm,
    };
    static const unsigned bytes[] = { 16, 4, 8, 4, 8, 4, 4, 4, 4, 2, 2, 2, 2, 4 };
    MTLTextureSwizzleChannels swizzle = MTLTextureSwizzleChannelsDefault;
    if (compact == 11)
        swizzle = MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue,
            MTLTextureSwizzleOne);
    else if (compact == 12)
        swizzle = MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleGreen, MTLTextureSwizzleBlue,
            MTLTextureSwizzleAlpha, MTLTextureSwizzleRed);
    else if (compact == 3)
        swizzle = MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleOne, MTLTextureSwizzleRed, MTLTextureSwizzleRed,
            MTLTextureSwizzleOne);
    else if (compact == 4)
        swizzle = MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleRed, MTLTextureSwizzleGreen,
            MTLTextureSwizzleGreen, MTLTextureSwizzleOne);
    else if (compact >= 5 && compact <= 8)
        swizzle = MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleRed,
            compact == 6 || compact == 7 ? MTLTextureSwizzleOne :
                                           MTLTextureSwizzleZero,
            compact == 7 || compact == 8 ? MTLTextureSwizzleOne :
                                           MTLTextureSwizzleZero,
            MTLTextureSwizzleZero);
    unsigned bytesPerPixel = bytes[compact];
    BOOL rawBytes = compact == 1 || compact == NV2AMetalTextureStorageSnorm8;
    unsigned lanes = compact >= 9 && compact <= 12 ? 1 :
                     rawBytes || compact <= 2      ? 4 :
                                                     bytesPerPixel / 4;
    unsigned headerWords = compact ? 10 : 9;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor new];
    descriptor.textureType = kind == 1 ? MTLTextureType2D :
                             kind == 2 ? MTLTextureType3D :
                                         MTLTextureTypeCube;
    descriptor.pixelFormat = formats[compact];
    descriptor.swizzle = swizzle;
    descriptor.width = width;
    descriptor.height = height;
    descriptor.depth = depth;
    descriptor.mipmapLevelCount = levels;
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage =
        MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> source =
        [commands.device newTextureWithDescriptor:descriptor];
    assert(source);
    for (unsigned face = 0; face < (kind == 3 ? 6u : 1u); face++) {
        for (unsigned level = 0; level < levels; level++) {
            unsigned w = MAX(1u, width >> level), h = MAX(1u, height >> level),
                     d = MAX(1u, depth >> level);
            NSMutableData *seed =
                [NSMutableData dataWithLength:w * h * d * bytesPerPixel];
            for (unsigned z = 0; z < d; z++)
                for (unsigned y = 0; y < h; y++)
                    for (unsigned x = 0; x < w * lanes; x++) {
                        if (compact == 2 || (compact >= 9 && compact <= 12)) {
                            uint16_t word =
                                (uint16_t)value(face, level, z, y, x);
                            memcpy((uint8_t *)seed.mutableBytes +
                                       ((z * h + y) * w * lanes + x) * 2,
                                   &word, 2);
                            continue;
                        }
                        if (rawBytes) {
                            ((uint8_t *)
                                 seed.mutableBytes)[(z * h + y) * w * 4 + x] =
                                byte_value(face, level, z, y, x);
                            continue;
                        }
                        uint32_t word = value(face, level, z, y, x);
                        memcpy((uint8_t *)seed.mutableBytes +
                                   ((z * h + y) * w * lanes + x) * 4,
                               &word, 4);
                    }
            [source replaceRegion:MTLRegionMake3D(0, 0, 0, w, h, d)
                      mipmapLevel:level
                            slice:face
                        withBytes:seed.bytes
                      bytesPerRow:w * bytesPerPixel
                    bytesPerImage:w * h * bytesPerPixel];
        }
    }
    unsigned base = view ? 1 : 0;
    id<MTLTexture> bound =
        view ?
            [source
                newTextureViewWithPixelFormat:descriptor.pixelFormat
                                  textureType:descriptor.textureType
                                       levels:NSMakeRange(base, levels - base)
                                       slices:NSMakeRange(0,
                                                          kind == 3 ? 6 : 1)] :
            source;
    assert(bound && bound.width == MAX(1u, width >> base));
    NSData *snapshot = nv2a_metal_texture_snapshot(bound, commands, &error);
    require(snapshot != nil, error);
    NSMutableData *expected = [NSMutableData new];
    for (unsigned face = 0; face < (kind == 3 ? 6u : 1u); face++)
        for (unsigned level = base; level < levels; level++)
            for (unsigned z = 0; z < MAX(1u, depth >> level); z++)
                for (unsigned y = 0; y < MAX(1u, height >> level); y++)
                    for (unsigned x = 0; x < MAX(1u, width >> level) * lanes;
                         x++) {
                        if (compact == 2 || (compact >= 9 && compact <= 12)) {
                            uint16_t word =
                                (uint16_t)value(face, level, z, y, x);
                            const uint8_t be[] = { word >> 8, word };
                            [expected appendBytes:be length:2];
                            compactBytes += 2;
                            continue;
                        }
                        if (rawBytes) {
                            uint8_t byte = byte_value(face, level, z, y, x);
                            [expected appendBytes:&byte length:1];
                            compactBytes++;
                            continue;
                        }
                        append(expected, value(face, level, z, y, x));
                        words++;
                    }
    NSMutableData *wire = [NSMutableData new];
    const uint32_t header[] = { 0x4d345458,
                                compact ? 2u : 1u,
                                kind,
                                MAX(1u, width >> base),
                                MAX(1u, height >> base),
                                MAX(1u, depth >> base),
                                levels - base,
                                0,
                                (uint32_t)expected.length,
                                compact };
    for (unsigned i = 0; i < headerWords; i++)
        append(wire, header[i]);
    [wire appendData:expected];
    assert([snapshot isEqualToData:wire]);
    require(nv2a_metal_texture_snapshot_validate(snapshot, &error), error);
    id<MTLTexture> restored =
        nv2a_metal_texture_restore(snapshot, commands, &error);
    require(restored != nil, error);
    NV2AMetalTextureSampler *sampler =
        [[NV2AMetalTextureSampler alloc] initWithDevice:commands.device
                                                  error:&error];
    require(sampler != nil, error);
    NV2AMetalSamplingUniforms sampling = {
        .enabled = 1,
        .address = { 1, 4, 5 },
        .min_linear = 1,
        .mag_linear = 1,
        .mip_filter = 2,
        .anisotropy = 8,
        .lod_bias = -15.5f,
        .border_color = { 0.125f, 0.5f, 0.75f, 1 },
    };
    NV2AMetalTextureBinding *binding =
        [sampler bindingForSnapshotTexture:restored
                                  sampling:&sampling
                                     error:&error];
    require(binding != nil, error);
    NV2AMetalSamplingUniforms copy = binding.sampling;
    assert(binding.texture == restored &&
           !memcmp(&copy, &sampling, sizeof(copy)));
    unsigned *integer_fields[] = {
        &sampling.enabled,    &sampling.address[0], &sampling.address[1],
        &sampling.address[2], &sampling.min_linear, &sampling.mag_linear,
        &sampling.mip_filter, &sampling.anisotropy,
    };
    for (unsigned i = 0; i < sizeof(integer_fields) / sizeof(*integer_fields);
         i++) {
        unsigned old = *integer_fields[i];
        *integer_fields[i] = UINT32_MAX;
        assert(![sampler bindingForSnapshotTexture:restored
                                          sampling:&sampling
                                             error:NULL]);
        *integer_fields[i] = old;
        rejected++;
    }
    sampling.lod_bias = 16;
    assert(!nv2a_metal_sampling_validate(&sampling, NULL));
    sampling.lod_bias = -15.5f;
    sampling.border_color[0] = INFINITY;
    assert(!nv2a_metal_sampling_validate(&sampling, NULL));
    rejected += 2;

    assert(restored != bound && restored.storageMode == MTLStorageModePrivate &&
           restored.pixelFormat == bound.pixelFormat &&
           restored.swizzle.red == swizzle.red &&
           restored.swizzle.green == swizzle.green &&
           restored.swizzle.blue == swizzle.blue &&
           restored.swizzle.alpha == swizzle.alpha &&
           restored.textureType == bound.textureType &&
           restored.width == bound.width && restored.height == bound.height &&
           restored.depth == bound.depth &&
           restored.mipmapLevelCount == bound.mipmapLevelCount);
    NSData *again = nv2a_metal_texture_snapshot(restored, commands, &error);
    require(again != nil, error);
    assert([again isEqualToData:snapshot]);
    NSMutableData *trailing = [snapshot mutableCopy];
    append(trailing, 0);
    assert(!nv2a_metal_texture_snapshot_validate(trailing, NULL));
    assert(!nv2a_metal_texture_restore(trailing, commands, NULL));
    rejected++;
    // Parser must reject every incomplete body without GPU access.
    for (NSUInteger n = 0; n < snapshot.length; n++) {
        NSData *shortened = [snapshot subdataWithRange:NSMakeRange(0, n)];
        assert(!nv2a_metal_texture_snapshot_validate(shortened, NULL));
        rejected++;
    }
    for (unsigned field = 0; field < headerWords; field++) {
        NSMutableData *bad = [snapshot mutableCopy];
        put(bad, field * 4, UINT32_MAX);
        assert(!nv2a_metal_texture_snapshot_validate(bad, NULL));
        assert(!nv2a_metal_texture_restore(bad, commands, NULL));
        rejected++;
    }
    NSMutableData *wrongVersion = [snapshot mutableCopy];
    put(wrongVersion, 4, compact ? 1 : 2);
    assert(!nv2a_metal_texture_snapshot_validate(wrongVersion, NULL));
    assert(!nv2a_metal_texture_restore(wrongVersion, commands, NULL));
    rejected++;
    if (compact) {
        for (unsigned format = 0; format <= NV2AMetalTextureStorageCount;
             format += NV2AMetalTextureStorageCount) {
            NSMutableData *bad = [snapshot mutableCopy];
            put(bad, 36, format);
            assert(!nv2a_metal_texture_snapshot_validate(bad, NULL));
            assert(!nv2a_metal_texture_restore(bad, commands, NULL));
            rejected++;
        }
    }
    require([commands beginWithError:&error] != nil, error);
    assert(!nv2a_metal_texture_snapshot(bound, commands, NULL));
    assert(commands.commandBuffer); // Existing caller recording survives.
    [commands cancel];
    images++;
}
int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        for (unsigned compact = 0; compact < NV2AMetalTextureStorageCount;
             compact++) {
            run(commands, 1, 5, 3, 1, 3, NO, compact);
            run(commands, 1, 8, 4, 1, 4, YES, compact);
            run(commands, 2, 4, 2, 4, 3, NO, compact);
            run(commands, 2, 8, 4, 8, 4, YES, compact);
            run(commands, 3, 4, 4, 1, 3, NO, compact);
            run(commands, 3, 8, 8, 1, 4, YES, compact);
        }
        run(commands, 1, 16, 16, 1, 5, NO, YES);
        const MTLPixelFormat unsupported[] = {
            MTLPixelFormatRGBA8Unorm_sRGB, MTLPixelFormatBGRA8Unorm,
            MTLPixelFormatRGBA8Snorm,      MTLPixelFormatRG16Float,
            MTLPixelFormatR32Float,        MTLPixelFormatRG32Float,
            MTLPixelFormatRGBA32Float
        };
        NV2AMetalTextureSampler *sampler =
            [[NV2AMetalTextureSampler alloc] initWithDevice:commands.device
                                                      error:&error];
        require(sampler != nil, error);
        NV2AMetalSamplingUniforms sampling = { .enabled = 1,
                                               .address = { 3, 3, 3 },
                                               .anisotropy = 1 };
        for (unsigned i = 0; i < sizeof(unsupported) / sizeof(*unsupported);
             i++) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:unsupported[i]
                                             width:1
                                            height:1
                                         mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead;
            if (unsupported[i] == MTLPixelFormatRGBA32Float ||
                unsupported[i] == MTLPixelFormatRGBA8Snorm)
                td.swizzle = MTLTextureSwizzleChannelsMake(
                    MTLTextureSwizzleBlue, MTLTextureSwizzleGreen,
                    MTLTextureSwizzleRed, MTLTextureSwizzleAlpha);
            id<MTLTexture> texture =
                [commands.device newTextureWithDescriptor:td];
            assert(texture);
            assert(!nv2a_metal_texture_snapshot(texture, commands, NULL));
            assert(![sampler bindingForSnapshotTexture:texture
                                              sampling:&sampling
                                                 error:NULL]);
            assert(!commands.commandBuffer);
            rejected += 2;
        }
        printf("Metal4 texture snapshots: %u images, %u exact float words, "
               "%u exact compact bytes, %u rejects PASS\n",
               images, words, compactBytes, rejected);
    }
    return 0;
}
