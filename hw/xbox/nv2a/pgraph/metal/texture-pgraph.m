/* Native texture register/DMA capture from gl/texture.c and glsl/psh.c
 * Copyright (c) 2012 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2018-2025 Matt Borgerson
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#include "hw/xbox/nv2a/pgraph/texture.h"
#pragma clang diagnostic pop
#import "texture-pgraph.h"

_Static_assert(NV2A_MAX_TEXTURES == 4, "Native texture stage count");
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

@interface NV2AMetalPGRAPHTextureSnapshot ()
- (instancetype)initSnapshot;
- (void)setTexture:(NV2AMetalCachedTexture *)texture
             stage:(NV2AMetalTextureStage)stage
             index:(unsigned)index
            hilo16:(BOOL)hilo16;
@end

static float register_float(PGRAPHState *pg, unsigned reg)
{
    uint32_t word = pgraph_reg_r(pg, reg);
    float value;
    memcpy(&value, &word, sizeof(value));
    return value;
}
static unsigned key_mask(unsigned format)
{
    return format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5 ||
                   format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8 ||
                   format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5 ||
                   format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8 ?
               0x00ffffff :
               UINT32_MAX;
}
/* Native-only formats absent from the shared GL table. 3D mips are resolved
 * below, independently of the shared helper's conservative GL workaround. */
static TextureShape native_16_shape(PGRAPHState *pg, unsigned i,
                                    unsigned format)
{
    uint32_t fmt = pgraph_reg_r(pg, NV_PGRAPH_TEXFMT0 + i * 4);
    uint32_t ctl = pgraph_reg_r(pg, NV_PGRAPH_TEXCTL0_0 + i * 4);
    unsigned width = GET_MASK(fmt, NV_PGRAPH_TEXFMT0_BASE_SIZE_U);
    unsigned height = GET_MASK(fmt, NV_PGRAPH_TEXFMT0_BASE_SIZE_V);
    unsigned depth = GET_MASK(fmt, NV_PGRAPH_TEXFMT0_BASE_SIZE_P);
    unsigned dimension = GET_MASK(fmt, NV_PGRAPH_TEXFMT0_DIMENSIONALITY);
    BOOL linear = format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16;
    unsigned min_level = GET_MASK(ctl, NV_PGRAPH_TEXCTL0_0_MIN_LOD_CLAMP);
    unsigned max_level = GET_MASK(ctl, NV_PGRAPH_TEXCTL0_0_MAX_LOD_CLAMP);
    unsigned levels = MIN(GET_MASK(fmt, NV_PGRAPH_TEXFMT0_MIPMAP_LEVELS),
                          MIN(max_level + 1, MAX(width, height) + 1));
    return (TextureShape){
        .cubemap = !!(fmt & NV_PGRAPH_TEXFMT0_CUBEMAPENABLE),
        .dimensionality = dimension,
        .color_format = format,
        .levels = linear ? 1 : levels,
        .width = linear ?
                     GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_TEXIMAGERECT0 + i * 4),
                              NV_PGRAPH_TEXIMAGERECT0_WIDTH) :
                     1u << width,
        .height =
            linear ? GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_TEXIMAGERECT0 + i * 4),
                              NV_PGRAPH_TEXIMAGERECT0_HEIGHT) :
                     1u << height,
        .depth = linear ? 1 : 1u << depth,
        .pitch = linear ?
                     GET_MASK(pgraph_reg_r(pg, NV_PGRAPH_TEXCTL1_0 + i * 4),
                              NV_PGRAPH_TEXCTL1_0_IMAGE_PITCH) :
                     0,
        .min_mipmap_level = linear ? min_level : MIN(levels - 1, min_level),
        .max_mipmap_level = linear ? max_level : MIN(levels - 1, max_level),
        .border = GET_MASK(fmt, NV_PGRAPH_TEXFMT0_BORDER_SOURCE) !=
                  NV_PGRAPH_TEXFMT0_BORDER_SOURCE_COLOR,
    };
}
@implementation NV2AMetalPGRAPHTextures {
    NV2AState *_d;
    BOOL _closed;
}
- (instancetype)initWithState:(NV2AState *)state
                     surfaces:(NV2AMetalSurfaceCache *)surfaces
                        error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    if (!state || !state->vram || state->vram_ptr != surfaces.vram.contents ||
        surfaces.vram.length != memory_region_size(state->vram)) {
        texture_pgraph_error(
            error, @"Texture adapter requires the live NV2A VRAM cache");
        return nil;
    }
    _d = state;
    _cache = [[NV2AMetalTextureCache alloc] initWithSurfaces:surfaces
                                                       error:error];
    return _cache ? self : nil;
}
- (void)flush
{
    [_cache removeAllTextures];
}
- (void)close
{
    [self flush];
    _closed = YES;
}
- (BOOL)mapDMA:(hwaddr)object
        offset:(NSUInteger)offset
        length:(NSUInteger)length
       address:(NSUInteger *)address
         error:(NSError **)error
{
    DMAObject dma = nv_dma_load(_d, object);
    /* Match nv_dma_map's existing physical base mask. Targets remain its
     * documented approximation; require the memory class used by surfaces. */
    NSUInteger base = dma.address & 0x07ffffff;
    if (dma.dma_class != NV_DMA_IN_MEMORY_CLASS || !length ||
        offset > dma.limit || length - 1 > dma.limit - offset ||
        base > _cache.surfaces.vram.length ||
        offset > _cache.surfaces.vram.length - base ||
        length > _cache.surfaces.vram.length - base - offset) {
        return texture_pgraph_error(
            error, @"Texture DMA span exceeds its limit or VRAM");
    }
    *address = base + offset;
    return YES;
}
- (BOOL)dirtyAddress:(NSUInteger)address
              length:(NSUInteger)length
               error:(NSError **)error
{
    if (!length)
        return YES;
    NSUInteger end = address + length, size = _cache.surfaces.vram.length;
    NSUInteger padding =
        (TARGET_PAGE_SIZE - end % TARGET_PAGE_SIZE) % TARGET_PAGE_SIZE;
    end += MIN(padding, size - end);
    address &= TARGET_PAGE_MASK;
    if (memory_region_test_and_clear_dirty(_d->vram, address, end - address,
                                           DIRTY_MEMORY_NV2A_TEX)) {
        BOOL ok = tcg_enabled() ?
                      [_cache.surfaces noticeTextureDirtyAtAddress:address
                                                            length:end - address
                                                             error:error] :
                      [_cache.surfaces observeCPUWriteAtAddress:address
                                                         length:end - address
                                                          error:error];
        if (!ok) {
            memory_region_set_client_dirty(_d->vram, address, end - address,
                                           DIRTY_MEMORY_NV2A_TEX);
            return NO;
        }
    }
    return YES;
}
- (NV2AMetalPGRAPHTextureSnapshot *)prepareWithError:(NSError **)error
{
    if (_closed) {
        texture_pgraph_error(error, @"Native PGRAPH textures are closed");
        return nil;
    }
    PGRAPHState *pg = &_d->pgraph;
    NV2AMetalPGRAPHTextureSnapshot *snapshot =
        [[NV2AMetalPGRAPHTextureSnapshot alloc] initSnapshot];
    BOOL pendingPalette = NO;
    for (unsigned i = 0; i < 4; i++) {
        if (!pgraph_is_texture_enabled(pg, i))
            continue;
        uint32_t fmt = pgraph_reg_r(pg, NV_PGRAPH_TEXFMT0 + i * 4);
        uint32_t ctl = pgraph_reg_r(pg, NV_PGRAPH_TEXCTL0_0 + i * 4);
        uint32_t filter = pgraph_reg_r(pg, NV_PGRAPH_TEXFILTER0 + i * 4);
        unsigned format = GET_MASK(fmt, NV_PGRAPH_TEXFMT0_COLOR);
        unsigned dimension = GET_MASK(fmt, NV_PGRAPH_TEXFMT0_DIMENSIONALITY);
        BOOL hilo16 =
            format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16 ||
            format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16;
        BOOL native16 =
            hilo16 || format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y16;
        BOOL linear =
            format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16 ||
            (format < ARRAY_SIZE(kelvin_color_format_info_map) &&
             kelvin_color_format_info_map[format].linear);
        if (format >= ARRAY_SIZE(kelvin_color_format_info_map) ||
            (!native16 &&
             !kelvin_color_format_info_map[format].bytes_per_pixel) ||
            (dimension != 2 && dimension != 3) || (linear && dimension != 2) ||
            (!linear && !GET_MASK(fmt, NV_PGRAPH_TEXFMT0_MIPMAP_LEVELS))) {
            texture_pgraph_error(error, @"Unsupported native texture "
                                        @"format/dimension state");
            goto fail;
        }
        TextureShape original = native16 ? native_16_shape(pg, i, format) :
                                           pgraph_get_texture_shape(pg, i);
        if (dimension == 3) {
            // EXT_texture3D: every axis halves to one; the largest sets the
            // chain length. Do not inherit the GL helper's 3D FIXME cutoff.
            unsigned full_levels = 1;
            for (unsigned size =
                     MAX(original.width, MAX(original.height, original.depth));
                 size > 1; size >>= 1)
                full_levels++;
            original.levels =
                MIN(GET_MASK(fmt, NV_PGRAPH_TEXFMT0_MIPMAP_LEVELS),
                    MIN(GET_MASK(ctl, NV_PGRAPH_TEXCTL0_0_MAX_LOD_CLAMP) + 1,
                        full_levels));
            original.min_mipmap_level =
                MIN(original.levels - 1,
                    GET_MASK(ctl, NV_PGRAPH_TEXCTL0_0_MIN_LOD_CLAMP));
            original.max_mipmap_level =
                MIN(original.levels - 1,
                    GET_MASK(ctl, NV_PGRAPH_TEXCTL0_0_MAX_LOD_CLAMP));
        }
        NV2AMetalTextureSource source = {
            .shape = { .format = original.color_format,
                       .dimension = original.dimensionality,
                       .width = original.width,
                       .height = original.height,
                       .depth = original.depth,
                       .levels = original.levels,
                       .pitch = original.pitch,
                       .min_level = original.min_mipmap_level,
                       .max_level = original.max_mipmap_level,
                       .cubemap = original.cubemap,
                       .border = original.border }
        };
        source.shape.signed_channels =
            !!(filter & NV_PGRAPH_TEXFILTER0_RSIGNED) |
            !!(filter & NV_PGRAPH_TEXFILTER0_GSIGNED) << 1 |
            !!(filter & NV_PGRAPH_TEXFILTER0_BSIGNED) << 2 |
            !!(filter & NV_PGRAPH_TEXFILTER0_ASIGNED) << 3;
        BOOL palette = format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8;
        uint32_t pal = pgraph_reg_r(pg, NV_PGRAPH_TEXPALETTE0 + i * 4);
        if (palette) {
            source.palette_length =
                (256u >> GET_MASK(pal, NV_PGRAPH_TEXPALETTE0_LENGTH)) * 4;
        }
        if (![_cache sourceLengthForShape:&source.shape
                            paletteLength:source.palette_length
                                   length:&source.length
                                    error:error] ||
            ![self mapDMA:fmt & NV_PGRAPH_TEXFMT0_CONTEXT_DMA ? pg->dma_b :
                                                                pg->dma_a
                   offset:pgraph_reg_r(pg, NV_PGRAPH_TEXOFFSET0 + i * 4)
                   length:source.length
                  address:&source.address
                    error:error] ||
            (palette &&
             ![self mapDMA:pal & NV_PGRAPH_TEXPALETTE0_CONTEXT_DMA ? pg->dma_b :
                                                                     pg->dma_a
                    offset:pal & NV_PGRAPH_TEXPALETTE0_OFFSET
                    length:source.palette_length
                   address:&source.palette_address
                     error:error]) ||
            ![self dirtyAddress:source.address
                         length:source.length
                          error:error] ||
            (palette && ![self dirtyAddress:source.palette_address
                                     length:source.palette_length
                                      error:error]))
            goto fail;
        NV2AMetalSamplerConfig sampler = {
            .filter = filter,
            .address = pgraph_reg_r(pg, NV_PGRAPH_TEXADDRESS0 + i * 4),
            .border_color = pgraph_reg_r(pg, NV_PGRAPH_BORDERCOLOR0 + i * 4),
            .anisotropy = 1u
                          << GET_MASK(ctl, NV_PGRAPH_TEXCTL0_0_MAX_ANISOTROPY)
        };
        NV2AMetalCachedTexture *texture = [_cache captureSource:&source
                                                        sampler:&sampler
                                                          frame:pg->frame_time
                                                          error:error];
        if (!texture)
            goto fail;
        pendingPalette |= palette && !texture.decodeValidated;
        NV2AMetalTextureStage stage = { 0 };
        if (pgraph_is_texture_stage_active(pg, i)) {
            stage.dimension = source.shape.dimension;
            stage.cubemap = source.shape.cubemap;
            stage.rectangle = texture.rectangle;
            stage.snorm = texture.mixedSignedHalf ?
                              NV2AMetalTextureNormalizationMixedHalf :
                              texture.signedNormalized;
            stage.signed_channels = source.shape.signed_channels;
            stage.shadow = texture.depth;
            stage.scale = texture.scale;
            stage.sampling = texture.binding.sampling;
            stage.alphakill = !!(ctl & NV_PGRAPH_TEXCTL0_0_ALPHAKILLEN);
            stage.colorkey_mode = ctl & NV_PGRAPH_TEXCTL0_0_COLORKEYMODE;
            stage.compare_mask =
                (pgraph_reg_r(pg, NV_PGRAPH_SHADERCLIPMODE) >> (4 * i)) & 15;
            stage.color_key =
                pgraph_reg_r(pg, NV_PGRAPH_COLORKEYCOLOR0 + i * 4);
            stage.color_key_mask = key_mask(format);
            if (source.shape.border && !texture.rectangle) {
                unsigned dimensions[] = { original.width, original.height,
                                          original.depth };
                for (unsigned j = 0; j < 3; j++) {
                    stage.border_logical_size[j] = dimensions[j];
                    stage.border_inv_real_size[j] =
                        1.f / MAX(16u, dimensions[j] * 2);
                }
            }
            if (GET_MASK(filter, NV_PGRAPH_TEXFILTER0_MIN) ==
                NV_PGRAPH_TEXFILTER0_MIN_CONVOLUTION_2D_LOD0) {
                stage.convolution =
                    GET_MASK(filter, NV_PGRAPH_TEXFILTER0_CONVOLUTION_KERNEL);
                if (stage.convolution !=
                        NV_PGRAPH_TEXFILTER0_CONVOLUTION_KERNEL_QUINCUNX &&
                    stage.convolution !=
                        NV_PGRAPH_TEXFILTER0_CONVOLUTION_KERNEL_GAUSSIAN_3) {
                    texture_pgraph_error(
                        error, @"Invalid native texture convolution kernel");
                    goto fail;
                }
            }
            if (i) {
                stage.bump_matrix[0] =
                    register_float(pg, NV_PGRAPH_BUMPMAT00 + (i - 1) * 4);
                stage.bump_matrix[1] =
                    register_float(pg, NV_PGRAPH_BUMPMAT01 + (i - 1) * 4);
                stage.bump_matrix[2] =
                    register_float(pg, NV_PGRAPH_BUMPMAT10 + (i - 1) * 4);
                stage.bump_matrix[3] =
                    register_float(pg, NV_PGRAPH_BUMPMAT11 + (i - 1) * 4);
                stage.bump_scale =
                    register_float(pg, NV_PGRAPH_BUMPSCALE1 + (i - 1) * 4);
                stage.bump_offset =
                    register_float(pg, NV_PGRAPH_BUMPOFFSET1 + (i - 1) * 4);
            }
        }
        [snapshot setTexture:texture
                       stage:stage
                       index:i
                      hilo16:hilo16 && stage.dimension];
    }
    if (pendingPalette &&
        (![_cache.surfaces submitWithError:error] ||
         ![_cache.surfaces waitUntilIdleWithError:error] ||
         ![snapshot validateCompletedWithError:error]))
        goto fail;
    for (unsigned i = 0; i < 4; i++) {
        if (snapshot.enabledMask & (1u << i))
            pg->texture_dirty[i] = false;
    }
    return snapshot;
fail:
    [_cache.surfaces cancel];
    return nil;
}
@end
