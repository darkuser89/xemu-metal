/* Portable frozen texture stages; no live NV2A/VM dependencies.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "texture-pgraph.h"
#import "texture-snapshot.h"
#include <stdint.h>
#include <string.h>

static BOOL texture_pgraph_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.pgraph-textures"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}
static uint32_t stage_read_be(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 |
           p[3];
}
static void stage_write_be(uint8_t *p, uint32_t word)
{
    p[0] = word >> 24;
    p[1] = word >> 16;
    p[2] = word >> 8;
    p[3] = word;
}

enum { StageRecordWords = 55, StageLegacyRecordWords = 54 };
_Static_assert(sizeof(NV2AMetalTextureStage) == 38 * 4 &&
                   sizeof(NV2AMetalSamplingUniforms) == 13 * 4,
               "Texture stage snapshot scalar layout");
typedef struct TextureRecord {
    unsigned index, scale, flags;
    NV2AMetalTextureStage stage;
    NV2AMetalSamplingUniforms sampling;
    NSData *image;
} TextureRecord;
static void stage_words(void *target, const uint8_t *source, size_t bytes)
{
    for (size_t i = 0; i < bytes; i += 4) {
        uint32_t word = (uint32_t)stage_read_be(source + i);
        memcpy((uint8_t *)target + i, &word, 4);
    }
}
static void stage_append(NSMutableData *data, const void *source, size_t bytes)
{
    for (size_t i = 0; i < bytes; i += 4) {
        uint32_t word;
        memcpy(&word, (const uint8_t *)source + i, 4);
        uint8_t wire[4];
        stage_write_be(wire, word);
        [data appendBytes:wire length:4];
    }
}
static BOOL stage_decode(NSData *data, TextureRecord *records,
                         unsigned *enabled, NSError **error)
{
    if (data.length < 12 || data.length > NV2A_METAL_TEXTURE_SNAPSHOT_MAX)
        return texture_pgraph_error(error,
                                    @"Invalid texture-stage snapshot length");
    const uint8_t *bytes = data.bytes;
    unsigned mask = (uint32_t)stage_read_be(bytes + 8);
    unsigned version = (uint32_t)stage_read_be(bytes + 4);
    unsigned record_words =
        version == 1 ? StageLegacyRecordWords : StageRecordWords;
    unsigned stage_words_count = version == 1 ? 37 : 38;
    if ((uint32_t)stage_read_be(bytes) != 0x4d345453 ||
        (version != 1 && version != 2 && version != 3) || mask > 15)
        return texture_pgraph_error(error,
                                    @"Invalid texture-stage snapshot header");
    NSUInteger offset = 12;
    for (unsigned i = 0; i < 4; i++) {
        if (!(mask & (1u << i)))
            continue;
        if (data.length - offset < record_words * 4)
            return texture_pgraph_error(error,
                                        @"Truncated texture-stage record");
        uint32_t words[StageRecordWords] = { 0 };
        stage_words(words, bytes + offset, record_words * 4);
        NSUInteger size = words[3];
        if (words[0] != i || !words[1] || words[1] > 16384 ||
            words[2] > (version >= 3 ? 31 : 7) ||
            size > data.length - offset - record_words * 4)
            return texture_pgraph_error(error,
                                        @"Invalid texture-stage metadata");
        TextureRecord record = { .index = i,
                                 .scale = words[1],
                                 .flags = words[2] };
        memcpy(&record.stage, words + 4, stage_words_count * 4);
        memcpy(&record.sampling, words + 4 + stage_words_count,
               sizeof(record.sampling));
        NSData *image = [data
            subdataWithRange:NSMakeRange(offset + record_words * 4, size)];
        if (!nv2a_metal_texture_snapshot_validate(image, error) ||
            !nv2a_metal_sampling_validate(&record.sampling, error))
            return NO;
        unsigned kind =
            (uint32_t)stage_read_be((const uint8_t *)image.bytes + 8);
        if ((record.flags & 1) && kind != 1)
            return texture_pgraph_error(error,
                                        @"Invalid restored rectangle texture");
        const NV2AMetalTextureStage *s = &record.stage;
        const uint8_t *imageBytes = image.bytes;
        BOOL half4 = stage_read_be(imageBytes + 4) == 2 &&
                     stage_read_be(imageBytes + 36) == 2;
        BOOL mixedHalf = !!(record.flags & 16);
        if (mixedHalf != (s->snorm == NV2AMetalTextureNormalizationMixedHalf) ||
            (mixedHalf &&
             (!half4 || record.sampling.enabled != 1 || (record.flags & 14) ||
              !s->signed_channels || s->signed_channels >= 15)))
            return texture_pgraph_error(error,
                                        @"Invalid mixed Signed8 half capture");
        if (half4 && ((!mixedHalf && (s->signed_channels != 15 || s->snorm)) ||
                      (record.flags & 8) || !s->dimension || s->shadow))
            return texture_pgraph_error(
                error, @"Invalid compact signed8 texture capture");
        if (((record.flags & 8) &&
             (!s->dimension || s->snorm || s->shadow ||
              (s->signed_channels && s->signed_channels != 15))) ||
            s->signed_channels > 15 ||
            (s->signed_channels &&
             (!s->dimension ||
              s->snorm == NV2AMetalTextureNormalizationLegacySigned ||
              s->shadow)))
            return texture_pgraph_error(error,
                                        @"Invalid signed8 texture capture");
        if (s->dimension) {
            if ((s->dimension != 2 && s->dimension != 3) || s->cubemap > 1 ||
                s->rectangle > 1 ||
                s->snorm > NV2AMetalTextureNormalizationMixedHalf ||
                s->shadow > 1 || s->scale != record.scale ||
                kind != (s->cubemap        ? 3u :
                         s->dimension == 3 ? 2u :
                                             1u) ||
                s->rectangle != !!(record.flags & 1) ||
                s->snorm != (mixedHalf ?
                                 NV2AMetalTextureNormalizationMixedHalf :
                                 !!(record.flags & 2)) ||
                s->shadow != !!(record.flags & 4) ||
                memcmp(&s->sampling, &record.sampling, sizeof(s->sampling)))
                return texture_pgraph_error(
                    error, @"Inconsistent restored texture stage");
        } else if (s->sampling.enabled) {
            return texture_pgraph_error(error,
                                        @"Inactive restored stage is sampling");
        }
        record.image = image;
        if (records)
            records[i] = record;
        offset += record_words * 4 + size;
    }
    if (offset != data.length)
        return texture_pgraph_error(error,
                                    @"Surplus texture-stage snapshot bytes");
    if (enabled)
        *enabled = mask;
    return YES;
}

@interface NV2AMetalPGRAPHTextureSnapshot ()
- (instancetype)initSnapshot;
- (void)setTexture:(NV2AMetalCachedTexture *)texture
             stage:(NV2AMetalTextureStage)stage
             index:(unsigned)index
            hilo16:(BOOL)hilo16;
@end
@implementation NV2AMetalPGRAPHTextureSnapshot {
    NV2AMetalCachedTexture *_textures[4];
    NV2AMetalTextureStage _stages[4];
    unsigned _hilo16Mask;
}
+ (instancetype)emptySnapshot
{
    return [[self alloc] initSnapshot];
}
- (instancetype)initSnapshot
{
    return [super init];
}
- (void)setTexture:(NV2AMetalCachedTexture *)texture
             stage:(NV2AMetalTextureStage)stage
             index:(unsigned)index
            hilo16:(BOOL)hilo16
{
    _textures[index] = texture;
    _stages[index] = stage;
    _enabledMask |= 1u << index;
    if (hilo16)
        _hilo16Mask |= 1u << index;
}
- (NSData *)snapshotWithCommands:(NV2AMetalCommands *)commands
                           error:(NSError **)error
{
    if (![self validateCompletedWithError:error])
        return nil;
    NSMutableData *data = [NSMutableData new];
    uint32_t header[] = { 0x4d345453, 3, _enabledMask };
    stage_append(data, header, sizeof(header));
    for (unsigned i = 0; i < 4; i++) {
        if (!(_enabledMask & (1u << i)))
            continue;
        NV2AMetalCachedTexture *texture = _textures[i];
        NSData *image = nv2a_metal_texture_snapshot(texture.binding.texture,
                                                    commands, error);
        if (!image)
            return nil;
        if (data.length >
                NV2A_METAL_TEXTURE_SNAPSHOT_MAX - StageRecordWords * 4 ||
            image.length > NV2A_METAL_TEXTURE_SNAPSHOT_MAX - data.length -
                               StageRecordWords * 4) {
            texture_pgraph_error(error,
                                 @"Texture-stage snapshot exceeds host bound");
            return nil;
        }
        uint32_t words[StageRecordWords] = {
            i, texture.scale,
            texture.rectangle | texture.signedNormalized << 1 |
                texture.depth << 2 | !!(_hilo16Mask & (1u << i)) << 3 |
                texture.mixedSignedHalf << 4,
            (uint32_t)image.length
        };
        memcpy(words + 4, &_stages[i], sizeof(_stages[i]));
        NV2AMetalSamplingUniforms sampling = texture.binding.sampling;
        memcpy(words + 42, &sampling, sizeof(sampling));
        stage_append(data, words, sizeof(words));
        [data appendData:image];
    }
    return [data copy];
}
+ (BOOL)validateSnapshot:(NSData *)data
                uniforms:(const NV2AMetalPixelUniforms *)uniforms
                   error:(NSError **)error
{
    TextureRecord records[4] = { 0 };
    unsigned mask;
    if (!uniforms || !stage_decode(data, records, &mask, error))
        return NO;
    if (uniforms->hilo16_mask & ~mask)
        return texture_pgraph_error(error, @"Unbound HILO16 pixel stage");
    for (unsigned i = 0; i < 4; i++) {
        if (!(mask & (1u << i)))
            continue;
        NV2AMetalTextureStage stage = uniforms->textures[i];
        // Shader rebinding can update compare bits while retaining bindings.
        stage.compare_mask = records[i].stage.compare_mask;
        if (memcmp(&stage, &records[i].stage, sizeof(stage)) ||
            !!(uniforms->hilo16_mask & (1u << i)) != !!(records[i].flags & 8))
            return texture_pgraph_error(
                error, @"Pixel and texture-stage captures disagree");
    }
    return YES;
}
+ (BOOL)validateSnapshot:(NSData *)data error:(NSError **)error
{
    return stage_decode(data, NULL, NULL, error);
}
- (instancetype)initWithSnapshot:(NSData *)data
                        commands:(NV2AMetalCommands *)commands
                           error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    TextureRecord records[4] = { 0 };
    unsigned mask;
    if (!stage_decode(data, records, &mask, error))
        return nil; // Validate every stage before the first GPU allocation.
    NV2AMetalTextureSampler *sampler =
        [[NV2AMetalTextureSampler alloc] initWithDevice:commands.device
                                                  error:error];
    if (!sampler)
        return nil;
    for (unsigned i = 0; i < 4; i++) {
        if (!(mask & (1u << i)))
            continue;
        TextureRecord r = records[i];
        id<MTLTexture> image =
            nv2a_metal_texture_restore(r.image, commands, error);
        if (!image)
            return nil;
        NV2AMetalTextureBinding *binding =
            [sampler bindingForSnapshotTexture:image
                                      sampling:&r.sampling
                                         error:error];
        NV2AMetalCachedTexture *texture =
            binding ? [[NV2AMetalCachedTexture alloc]
                          initWithRestoredBinding:binding
                                            scale:r.scale
                                            flags:r.flags & 23] :
                      nil;
        if (!texture) {
            texture_pgraph_error(error, @"Cannot restore bound texture stage");
            return nil;
        }
        [self setTexture:texture stage:r.stage index:i hilo16:!!(r.flags & 8)];
    }
    return self;
}
- (NV2AMetalCachedTexture *)textureAtIndex:(NSUInteger)index
{
    return index < 4 ? _textures[index] : nil;
}
- (BOOL)applyToUniforms:(NV2AMetalPixelUniforms *)uniforms
               textures:(NV2AMetalPixelTexture *)textures
                  error:(NSError **)error
{
    if (!uniforms || !textures) {
        return texture_pgraph_error(error,
                                    @"Missing texture stage export storage");
    }
    uniforms->hilo16_mask = _hilo16Mask;
    for (unsigned i = 0; i < 4; i++) {
        uniforms->textures[i] = _stages[i];
        textures[i].texture = _textures[i].binding.texture;
        textures[i].sampler = _textures[i].binding.sampler;
    }
    return YES;
}
- (BOOL)validateCompletedWithError:(NSError **)error
{
    for (unsigned i = 0; i < 4; i++) {
        if (_textures[i] && ![_textures[i] validateCompletedWithError:error]) {
            return NO;
        }
    }
    return YES;
}
@end
