/* Real PGRAPH texture register helpers and native GPU boundary tests.
 * VM/RAM/DMA registration is mocked; no VM/window/application is started.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#include "hw/xbox/nv2a/pgraph/texture.h"
#pragma clang diagnostic pop
#import "hw/xbox/nv2a/pgraph/metal/texture-pgraph.h"
#import "hw/xbox/nv2a/pgraph/metal/clear.h"
#include "hw/xbox/nv2a/pgraph/metal/geometry-types.h"
#include "test-metal-legacy-cube.h"
#include "test-metal-texture-readback.h"
#import "hw/xbox/nv2a/pgraph/metal/texture-snapshot.h"

static NV2AState *state;
static NV2AMetalSurfaceCache *surfaces;
static NV2AMetalPGRAPHTextures *adapter;
static DMAObject dma_a, dma_b;
static bool dirty_pages[64];
static unsigned vram_size = 65536;
static unsigned checks, dirty_checks, dirty_restores, dma_loads;
@interface TextureTestSurfaces : NV2AMetalSurfaceCache
@property(nonatomic) NSUInteger submissions, waits;
@property(nonatomic) BOOL failNextWait, cancelNextSubmit;
@end
@implementation TextureTestSurfaces
- (BOOL)submitWithError:(NSError **)error
{
    self.submissions++;
    if (self.cancelNextSubmit) {
        self.cancelNextSubmit = NO;
        [self cancel];
        if (error)
            *error = [NSError errorWithDomain:@"test.texture.cancelled"
                                        code:1 userInfo:nil];
        return NO;
    }
    return [super submitWithError:error];
}
- (BOOL)waitUntilIdleWithError:(NSError **)error
{
    self.waits++;
    if (self.failNextWait) {
        self.failNextWait = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.texture.completion"
                                        code:1 userInfo:nil];
        return NO;
    }
    return [super waitUntilIdleWithError:error];
}
@end
bool tcg_allowed = true;
uint64_t memory_region_size(MemoryRegion *mr)
{
    assert(mr == state->vram);
    return vram_size;
}
DMAObject nv_dma_load(NV2AState *d, hwaddr object)
{
    assert(d == state &&
           (object == d->pgraph.dma_a || object == d->pgraph.dma_b));
    dma_loads++;
    return object == d->pgraph.dma_a ? dma_a : dma_b;
}
void *nv_dma_map(NV2AState *d, hwaddr object, hwaddr *length)
{
    (void)d;
    (void)object;
    (void)length;
    /* Native capture must validate full spans, not call unchecked GL helpers.
     */
    abort();
}
bool memory_region_test_and_clear_dirty(MemoryRegion *mr, hwaddr address,
                                        hwaddr length, unsigned client)
{
    assert(mr == state->vram && client == DIRTY_MEMORY_NV2A_TEX);
    assert(address % 4096 == 0 && length && length <= vram_size - address);
    dirty_checks++;
    bool dirty = false;
    for (unsigned i = (unsigned)address / 4096;
         i <= (address + length - 1) / 4096; i++) {
        dirty |= dirty_pages[i];
        dirty_pages[i] = false;
    }
    return dirty;
}
void memory_region_set_client_dirty(MemoryRegion *mr, hwaddr address,
                                    hwaddr length, unsigned client)
{
    assert(mr == state->vram && client == DIRTY_MEMORY_NV2A_TEX);
    assert(length && address < vram_size && length <= vram_size - address);
    dirty_restores++;
    for (unsigned i = (unsigned)address / 4096;
         i <= (address + length - 1) / 4096; i++)
        dirty_pages[i] = true;
}
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "PGRAPH textures: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static void finish(void)
{
    NSError *error = nil;
    require([surfaces submitWithError:&error], error);
    require([surfaces waitUntilIdleWithError:&error], error);
}
static unsigned stage_snapshots;
static NSData *legacy_stage_fixture(NSData *current)
{
    const uint8_t *bytes = current.bytes;
    assert(ldl_be_p(bytes + 4) == 3);
    NSMutableData *old = [NSMutableData dataWithBytes:bytes length:12];
    stl_be_p((uint8_t *)old.mutableBytes + 4, 1);
    unsigned mask = ldl_be_p(bytes + 8);
    NSUInteger offset = 12;
    for (unsigned i = 0; i < 4; i++) {
        if (!(mask & (1u << i)))
            continue;
        unsigned length = ldl_be_p(bytes + offset + 12);
        assert(ldl_be_p(bytes + offset + (4 + 37) * 4) == 0);
        [old appendData:[current subdataWithRange:NSMakeRange(offset,
                                                              (4 + 37) * 4)]];
        [old
            appendData:[current subdataWithRange:NSMakeRange(offset + 42 * 4,
                                                             13 * 4 + length)]];
        offset += 55 * 4 + length;
    }
    assert(offset == current.length);
    return old;
}

static void mixed_half_metadata_tests(NSData *data,
                                      NV2AMetalPGRAPHTextureSnapshot *snapshot)
{
    static BOOL checked;
    if (checked || snapshot.enabledMask != 1 ||
        ![snapshot textureAtIndex:0].mixedSignedHalf)
        return;
    NSError *error = nil;
    const unsigned stageOffset = 12 + 16;
    const unsigned invalid[][2] = {
        { 20, 0 },
        { 20, 18 },
        { 20, 20 },
        { 20, 24 },
        { stageOffset + offsetof(NV2AMetalTextureStage, signed_channels), 0 },
        { stageOffset + offsetof(NV2AMetalTextureStage, signed_channels), 15 },
        { stageOffset + offsetof(NV2AMetalTextureStage, snorm), 0 },
        { stageOffset + offsetof(NV2AMetalTextureStage, snorm), 1 },
        { stageOffset + offsetof(NV2AMetalTextureStage, snorm), 3 },
        { stageOffset + offsetof(NV2AMetalTextureStage, sampling), 0 },
        { 12 + 42 * 4, 0 },
        { 4, 2 },
        { 4, 1 }
    };
    for (unsigned i = 0; i < G_N_ELEMENTS(invalid); i++) {
        NSMutableData *bad = [data mutableCopy];
        stl_be_p((uint8_t *)bad.mutableBytes + invalid[i][0], invalid[i][1]);
        assert(![NV2AMetalPGRAPHTextureSnapshot validateSnapshot:bad
                                                           error:NULL]);
        assert(![[NV2AMetalPGRAPHTextureSnapshot alloc]
            initWithSnapshot:bad
                    commands:surfaces.commands
                       error:NULL]);
    }
    /* A legacy mixed Float32 record contains logical values and no codec
     * flag. Rebuild that representation independently and retain its bytes. */
    require([surfaces prepareGPUReadAtAddress:0 length:0 error:&error], error);
    id<MTLTexture> packed = [snapshot textureAtIndex:0].binding.texture;
    const uint8_t *bytes = data.bytes;
    unsigned signedMask = ldl_be_p(
        bytes + stageOffset + offsetof(NV2AMetalTextureStage, signed_channels));
    id<MTLTexture> logical = test_metal_float_reference_decoded(
        surfaces.commands, packed, 15u ^ signedMask);
    id<MTLBuffer> expected =
        test_metal_read_texture(surfaces.commands, logical, 0, 0);
    finish();
    NSData *image =
        nv2a_metal_texture_snapshot(logical, surfaces.commands, &error);
    require(image != nil, error);
    NSMutableData *legacy = [NSMutableData dataWithBytes:data.bytes
                                                  length:12 + 55 * 4];
    stl_be_p((uint8_t *)legacy.mutableBytes + 20, 0);
    stl_be_p((uint8_t *)legacy.mutableBytes + 24, (uint32_t)image.length);
    stl_be_p((uint8_t *)legacy.mutableBytes + stageOffset +
                 offsetof(NV2AMetalTextureStage, snorm),
             0);
    [legacy appendData:image];
    require([NV2AMetalPGRAPHTextureSnapshot validateSnapshot:legacy
                                                       error:&error],
            error);
    NV2AMetalPGRAPHTextureSnapshot *old =
        [[NV2AMetalPGRAPHTextureSnapshot alloc]
            initWithSnapshot:legacy
                    commands:surfaces.commands
                       error:&error];
    require(old != nil, error);
    assert(![old textureAtIndex:0].mixedSignedHalf);
    NV2AMetalPixelUniforms u = {};
    NV2AMetalPixelTexture textures[4] = {};
    require([old applyToUniforms:&u textures:textures error:&error], error);
    assert(u.textures[0].snorm == 0 &&
           u.textures[0].signed_channels == signedMask &&
           textures[0].texture.pixelFormat == MTLPixelFormatRGBA32Float);
    require([surfaces prepareGPUReadAtAddress:0 length:0 error:&error], error);
    id<MTLBuffer> actual =
        test_metal_read_texture(surfaces.commands, textures[0].texture, 0, 0);
    finish();
    NSUInteger row = (logical.width * 16 + 255) & ~(NSUInteger)255;
    for (unsigned y = 0; y < logical.height; y++)
        assert(!memcmp((uint8_t *)actual.contents + row * y,
                       (uint8_t *)expected.contents + row * y,
                       logical.width * 16));
    NSData *again = [old snapshotWithCommands:surfaces.commands error:&error];
    require(again != nil, error);
    assert([again isEqualToData:legacy]);
    checked = YES;
    puts(
        "Metal4 mixed Signed8:13 invalid storage/normalization/version records "
        "rejected;legacy mixed Float32 restore/pixels/canonical bytes PASS");
}

static void stage_roundtrip(NV2AMetalPGRAPHTextureSnapshot *snapshot)
{
    NSError *error = nil;
    finish();
    NSData *data = [snapshot snapshotWithCommands:surfaces.commands
                                            error:&error];
    require(data != nil, error);
    require([NV2AMetalPGRAPHTextureSnapshot validateSnapshot:data error:&error],
            error);
    NV2AMetalPGRAPHTextureSnapshot *copy =
        [[NV2AMetalPGRAPHTextureSnapshot alloc]
            initWithSnapshot:data
                    commands:surfaces.commands
                       error:&error];
    require(copy != nil, error);
    assert(copy.enabledMask == snapshot.enabledMask);
    NV2AMetalPixelUniforms a = { 0 }, b = { 0 };
    NV2AMetalPixelTexture before[4] = { 0 }, after[4] = { 0 };
    require([snapshot applyToUniforms:&a textures:before error:&error], error);
    require([copy applyToUniforms:&b textures:after error:&error], error);
    assert(!memcmp(a.textures, b.textures, sizeof(a.textures)) &&
           a.hilo16_mask == b.hilo16_mask);
    for (unsigned i = 0; i < 4; i++) {
        if (!(copy.enabledMask & (1u << i)))
            continue;
        NV2AMetalCachedTexture *x = [snapshot textureAtIndex:i],
                               *y = [copy textureAtIndex:i];
        assert(x.binding.texture != y.binding.texture && x.scale == y.scale &&
               x.rectangle == y.rectangle &&
               x.signedNormalized == y.signedNormalized &&
               x.mixedSignedHalf == y.mixedSignedHalf && x.depth == y.depth);
        NV2AMetalSamplingUniforms sx = x.binding.sampling,
                                  sy = y.binding.sampling;
        assert(!memcmp(&sx, &sy, sizeof(sx)));
        require([y validateCompletedWithError:&error], error);
    }
    NSData *again = [copy snapshotWithCommands:surfaces.commands error:&error];
    require(again != nil, error);
    assert([again isEqualToData:data]);
    mixed_half_metadata_tests(data, snapshot);
    static BOOL halfMetadataChecked;
    if (!halfMetadataChecked && copy.enabledMask &&
        !(copy.enabledMask & (copy.enabledMask - 1))) {
        unsigned stage = (unsigned)__builtin_ctz(copy.enabledMask);
        if ([copy textureAtIndex:stage].binding.texture.pixelFormat ==
                MTLPixelFormatRGBA16Float &&
            ![copy textureAtIndex:stage].mixedSignedHalf) {
            for (unsigned mask = 0; mask < 15; mask++) {
                NSMutableData *bad = [data mutableCopy];
                stl_be_p((uint8_t *)bad.mutableBytes + 12 + 16 +
                             offsetof(NV2AMetalTextureStage, signed_channels),
                         mask);
                assert(![NV2AMetalPGRAPHTextureSnapshot validateSnapshot:bad
                                                                   error:NULL]);
                assert(![[NV2AMetalPGRAPHTextureSnapshot alloc]
                    initWithSnapshot:bad
                            commands:surfaces.commands
                               error:NULL]);
            }
            halfMetadataChecked = YES;
            puts("Metal4 compact signed8:15 inconsistent half/mixed-mask "
                 "captures rejected before restore PASS");
        }
    }
    if (!stage_snapshots) {
        NSData *legacy = legacy_stage_fixture(data);
        require([NV2AMetalPGRAPHTextureSnapshot validateSnapshot:legacy
                                                           error:&error],
                error);
        NV2AMetalPGRAPHTextureSnapshot *old =
            [[NV2AMetalPGRAPHTextureSnapshot alloc]
                initWithSnapshot:legacy
                        commands:surfaces.commands
                           error:&error];
        require(old != nil, error);
        NV2AMetalPixelUniforms legacy_uniforms = { 0 };
        NV2AMetalPixelTexture legacy_textures[4] = { 0 };
        require([old applyToUniforms:&legacy_uniforms
                            textures:legacy_textures
                               error:&error],
                error);
        assert(
            !memcmp(a.textures, legacy_uniforms.textures, sizeof(a.textures)));
        NSData *upgraded = [old snapshotWithCommands:surfaces.commands
                                               error:&error];
        require(upgraded != nil, error);
        assert([upgraded isEqualToData:data]);
    }
    if (data.length > 176) {
        NSMutableData *bad_mask = [data mutableCopy];
        stl_be_p((uint8_t *)bad_mask.mutableBytes + 176, 16);
        assert(![NV2AMetalPGRAPHTextureSnapshot validateSnapshot:bad_mask
                                                           error:NULL]);
    }
    for (NSUInteger n = 0; n < data.length; n++) {
        NSData *shortened = [data subdataWithRange:NSMakeRange(0, n)];
        assert(![NV2AMetalPGRAPHTextureSnapshot validateSnapshot:shortened
                                                           error:NULL]);
    }
    unsigned offsets[] = { 0, 4, 8, 12, 16, 20, 24 };
    for (unsigned i = 0; i < ARRAY_SIZE(offsets); i++) {
        if (offsets[i] + 4 > data.length)
            continue;
        NSMutableData *bad = [data mutableCopy];
        stl_be_p((uint8_t *)bad.mutableBytes + offsets[i], UINT32_MAX);
        assert(![NV2AMetalPGRAPHTextureSnapshot validateSnapshot:bad
                                                           error:NULL]);
        assert(![[NV2AMetalPGRAPHTextureSnapshot alloc]
            initWithSnapshot:bad
                    commands:surfaces.commands
                       error:NULL]);
    }
    stage_snapshots++;
}
static void cpu_write(NSUInteger address, NSUInteger length)
{
    NSError *error = nil;
    require([surfaces prepareCPUAccessAtAddress:address
                                         length:length
                                          write:YES
                                          error:&error],
            error);
}
static void registers(unsigned i, unsigned format, unsigned width,
                      unsigned pitch, NSUInteger offset, bool dma_b_select)
{
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_TEXFMT0 + i * 4] =
        (format << 8) | (2 << 6) | NV_PGRAPH_TEXFMT0_BORDER_SOURCE | (1 << 16) |
        (2 << 20) | (2 << 24) |
        (dma_b_select ? NV_PGRAPH_TEXFMT0_CONTEXT_DMA : 0);
    pg->regs_[NV_PGRAPH_TEXCTL0_0 + i * 4] = NV_PGRAPH_TEXCTL0_0_ENABLE;
    pg->regs_[NV_PGRAPH_TEXCTL1_0 + i * 4] = pitch << 16;
    pg->regs_[NV_PGRAPH_TEXIMAGERECT0 + i * 4] = width << 16 | 4;
    pg->regs_[NV_PGRAPH_TEXOFFSET0 + i * 4] = (uint32_t)offset;
    pg->regs_[NV_PGRAPH_TEXFILTER0 + i * 4] = 1 << 16 | 1 << 24;
    pg->regs_[NV_PGRAPH_TEXADDRESS0 + i * 4] = 3 | 3 << 8 | 3 << 16;
    pg->regs_[NV_PGRAPH_SHADERPROG] &= ~(31u << (i * 5));
    pg->regs_[NV_PGRAPH_SHADERPROG] |= PS_TEXTUREMODES_PROJECT2D << (i * 5);
    pg->texture_dirty[i] = true;
}
static void only_stage0(void)
{
    for (unsigned i = 1; i < 4; i++)
        state->pgraph.regs_[NV_PGRAPH_TEXCTL0_0 + i * 4] = 0;
}
static NV2AMetalPGRAPHTextureSnapshot *prepare(void)
{
    NSError *error = nil;
    NV2AMetalPGRAPHTextureSnapshot *s = [adapter prepareWithError:&error];
    require(s != nil, error);
    return s;
}
static id<MTLBuffer> read_subresource(id<MTLTexture> t, unsigned level,
                                      unsigned face)
{
    NSError *error = nil;
    require([surfaces prepareGPUReadAtAddress:0 length:0 error:&error], error);
    return test_metal_read_texture(surfaces.commands, t, level, face);
}

static id<MTLBuffer> read_texture(NV2AMetalPGRAPHTextureSnapshot *s, unsigned i)
{
    NV2AMetalPixelUniforms u = { 0 };
    NV2AMetalPixelTexture bindings[4] = { 0 };
    NSError *error = nil;
    require([s applyToUniforms:&u textures:bindings error:&error], error);
    require([surfaces prepareGPUReadAtAddress:0 length:0 error:&error], error);
    return test_metal_read_texture_decoded(
        surfaces.commands, bindings[i].texture, 0, 0,
        u.textures[i].snorm == NV2AMetalTextureNormalizationMixedHalf ?
            (15u ^ u.textures[i].signed_channels) :
            0);
}
static void pixel(id<MTLBuffer> out, unsigned width, unsigned x, unsigned y,
                  float r, float g, float b, float a)
{
    NSUInteger row = ((NSUInteger)width * 16 + 255) & ~(NSUInteger)255;
    const float *p =
        (const float *)((const unsigned char *)out.contents + y * row + x * 16);
    float expected[] = { r, g, b, a };
    for (unsigned i = 0; i < 4; i++) {
        if (!isfinite(p[i]) || fabsf(p[i] - expected[i]) >= .000001f) {
            fprintf(stderr, "Texture %ux%u channel %u: %g expected %g\n", width,
                    (unsigned)y, i, p[i], expected[i]);
            abort();
        }
    }
}
static void float_register(unsigned reg, float value)
{
    memcpy(&state->pgraph.regs_[reg], &value, sizeof(value));
}
static void stage_capture_tests(void)
{
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    for (unsigned i = 0; i < 4; i++) {
        registers(i, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8, 4, 4,
                  64 + i * 64, i & 1);
        NSUInteger address =
            (i & 1 ? dma_b.address : dma_a.address) + 64 + i * 64;
        cpu_write(address, 16);
        memset(state->vram_ptr + address, 32 + i * 32, 16);
        pg->regs_[NV_PGRAPH_TEXCTL0_0 + i * 4] |=
            i << 4 | NV_PGRAPH_TEXCTL0_0_ALPHAKILLEN | 3;
        pg->regs_[NV_PGRAPH_TEXFILTER0 + i * 4] |= 0x1f00;
        pg->regs_[NV_PGRAPH_BORDERCOLOR0 + i * 4] = 0x66112233;
        pg->regs_[NV_PGRAPH_SHADERCLIPMODE] |= (5u << (i * 4));
        pg->regs_[NV_PGRAPH_COLORKEYCOLOR0 + i * 4] = 0x12345678 + i;
    }
    float_register(NV_PGRAPH_BUMPMAT00, 1.25f);
    float_register(NV_PGRAPH_BUMPMAT01, 2.5f);
    float_register(NV_PGRAPH_BUMPMAT10, 3.75f);
    float_register(NV_PGRAPH_BUMPMAT11, 4.5f);
    float_register(NV_PGRAPH_BUMPSCALE1, .75f);
    float_register(NV_PGRAPH_BUMPOFFSET1, -.25f);
    NV2AMetalPGRAPHTextureSnapshot *s = prepare();
    assert(s.enabledMask == 15 && dma_loads == 4 && dirty_checks == 4);
    NV2AMetalPixelUniforms u = { .depth_factor = 42 };
    NV2AMetalPixelTexture bindings[4];
    require([s applyToUniforms:&u textures:bindings error:&error], error);
    assert(u.depth_factor == 42 && ![s textureAtIndex:4]);
    assert(![s applyToUniforms:NULL textures:bindings error:&error]);
    for (unsigned i = 0; i < 4; i++) {
        assert(bindings[i].texture == [s textureAtIndex:i].binding.texture);
        assert(u.textures[i].dimension == 2 && u.textures[i].rectangle);
        assert(u.textures[i].scale == 1 && u.textures[i].alphakill);
        assert(u.textures[i].colorkey_mode == 3 &&
               u.textures[i].compare_mask == 5);
        assert(u.textures[i].color_key == 0x12345678 + i &&
               u.textures[i].color_key_mask == UINT32_MAX);
        assert(u.textures[i].sampling.anisotropy == 1u << i &&
               u.textures[i].sampling.lod_bias == -1);
        assert(!pg->texture_dirty[i]);
    }
    assert(u.textures[1].bump_matrix[0] == 1.25f &&
           u.textures[1].bump_matrix[3] == 4.5f);
    assert(u.textures[1].bump_scale == .75f &&
           u.textures[1].bump_offset == -.25f);
    id<MTLBuffer> outs[4];
    for (unsigned i = 0; i < 4; i++)
        outs[i] = read_texture(s, i);
    finish();
    require([s validateCompletedWithError:&error], error);
    stage_roundtrip(s);
    for (unsigned i = 0; i < 4; i++)
        pixel(outs[i], 4, 0, 0, (32 + i * 32) / 255.f, (32 + i * 32) / 255.f,
              (32 + i * 32) / 255.f, 1);
    pg->regs_[NV_PGRAPH_TEXFILTER0] = 2 << 16 | 2 << 24;
    pg->regs_[NV_PGRAPH_TEXCTL0_0 + 8] = 0;
    NV2AMetalPGRAPHTextureSnapshot *next = prepare();
    require([next applyToUniforms:&u textures:bindings error:&error], error);
    assert(next.enabledMask == 11 && !bindings[2].texture &&
           !u.textures[2].dimension);
    assert(u.textures[0].sampling.mag_linear &&
           ![s textureAtIndex:0].binding.sampling.mag_linear);
    assert([s textureAtIndex:0].binding.texture ==
           [next textureAtIndex:0].binding.texture);
    finish();
    /* External RAM writers may set dirty pages without a TCG CPU hook. */
    memset(state->vram_ptr + dma_a.address + 64, 0x2f, 16);
    dirty_pages[1] = true;
    NV2AMetalPGRAPHTextureSnapshot *external = prepare();
    assert([external textureAtIndex:0].binding.texture !=
           [next textureAtIndex:0].binding.texture);
    id<MTLBuffer> changed = read_texture(external, 0);
    finish();
    pixel(changed, 4, 0, 0, 0x2f / 255.f, 0x2f / 255.f, 0x2f / 255.f, 1);
    checks++;
}
static void layout_tests(void)
{
    NSError *error = nil;
    only_stage0();
    PGRAPHState *pg = &state->pgraph;
    registers(0, NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8, 4, 0, 512, false);
    pg->regs_[NV_PGRAPH_TEXFMT0] &= ~NV_PGRAPH_TEXFMT0_BORDER_SOURCE;
    cpu_write(dma_a.address + 512, 256);
    memset(state->vram_ptr + dma_a.address + 512, 0x44, 256);
    NV2AMetalPGRAPHTextureSnapshot *s = prepare();
    assert([s textureAtIndex:0].binding.texture.width == 16);
    NV2AMetalPixelUniforms u = { 0 };
    NV2AMetalPixelTexture bindings[4];
    require([s applyToUniforms:&u textures:bindings error:&error], error);
    assert(u.textures[0].border_logical_size[0] == 4 &&
           u.textures[0].border_inv_real_size[0] == .0625f);
    id<MTLBuffer> out = read_texture(s, 0);
    finish();
    pixel(out, 16, 15, 15, 0x44 / 255.f, 0x44 / 255.f, 0x44 / 255.f, 1);
    checks++;
    registers(0, NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8, 4, 0, 1024, false);
    pg->regs_[NV_PGRAPH_TEXFMT0] = NV_PGRAPH_TEXFMT0_BORDER_SOURCE | (3 << 6) |
                                   (NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8 << 8) |
                                   (2 << 16) | (3 << 20) | (3 << 24) |
                                   (2u << 28);
    pg->regs_[NV_PGRAPH_TEXCTL0_0] |= 1 << 6;
    /* Native 3D levels consume 8*8*4 + 4*4*2 = 288 bytes;
     * the old GL generic length helper overestimates this as 320 bytes. */
    cpu_write(dma_a.address + 1024, 288);
    memset(state->vram_ptr + dma_a.address + 1024, 0x55, 288);
    DMAObject original = dma_a;
    dma_a.limit = 1024 + 288 - 1;
    s = prepare();
    finish();
    require([s validateCompletedWithError:&error], error);
    stage_roundtrip(s);
    assert([s textureAtIndex:0].binding.texture.textureType ==
           MTLTextureType3D);
    assert([s textureAtIndex:0].binding.texture.mipmapLevelCount == 2);
    dma_a = original;
    checks++;
    registers(0, NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8, 4, 0, 2048, false);
    pg->regs_[NV_PGRAPH_TEXFMT0] |= NV_PGRAPH_TEXFMT0_CUBEMAPENABLE;
    cpu_write(dma_a.address + 2048, 768);
    memset(state->vram_ptr + dma_a.address + 2048, 0x66, 768);
    s = prepare();
    finish();
    require([s validateCompletedWithError:&error], error);
    stage_roundtrip(s);
    assert([s textureAtIndex:0].binding.texture.textureType ==
           MTLTextureTypeCube);
    checks++;
    registers(0, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_Y16_FIXED, 4, 8,
              3072, false);
    cpu_write(dma_a.address + 3072, 32);
    for (unsigned i = 0; i < 16; i++) {
        uint16_t v = 32768;
        memcpy(state->vram_ptr + dma_a.address + 3072 + i * 2, &v, 2);
    }
    s = prepare();
    require([s applyToUniforms:&u textures:bindings error:&error], error);
    assert(u.textures[0].shadow && [s textureAtIndex:0].depth);
    out = read_texture(s, 0);
    finish();
    pixel(out, 4, 0, 0, 32768 / 65535.f, 0, 0, 0);
    checks++;
}
static void compact16_register_tests(void)
{
    NSError *error = nil;
    only_stage0();
    PGRAPHState *pg = &state->pgraph;
    const unsigned formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y16,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y16,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R5G6B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5
    };
    for (unsigned f = 0; f < 4; f++) {
        for (unsigned layout = 0; layout < ((f & 1) ? 1u : 4u); layout++) {
            registers(0, formats[f], 4, 16, 4096, false);
            unsigned levels = 1, width = 4;
            if (layout == 1) {
                pg->regs_[NV_PGRAPH_TEXFMT0] |= NV_PGRAPH_TEXFMT0_CUBEMAPENABLE;
            } else if (layout == 2) {
                pg->regs_[NV_PGRAPH_TEXFMT0] = NV_PGRAPH_TEXFMT0_BORDER_SOURCE |
                                               (3 << 6) | (formats[f] << 8) |
                                               (2 << 16) | (3 << 20) |
                                               (3 << 24) | (2u << 28);
                pg->regs_[NV_PGRAPH_TEXCTL0_0] |= 1 << 6;
                levels = 2;
                width = 8;
            } else if (layout == 3) {
                pg->regs_[NV_PGRAPH_TEXFMT0] &=
                    ~NV_PGRAPH_TEXFMT0_MIPMAP_LEVELS;
                pg->regs_[NV_PGRAPH_TEXFMT0] |= 3 << 16;
                pg->regs_[NV_PGRAPH_TEXCTL0_0] |= 2 << 6 | 1 << 18;
                levels = 2;
                width = 2;
            }
            cpu_write(dma_a.address + 4096, 1536);
            for (unsigned i = 0; i < 768; i++) {
                state->vram_ptr[dma_a.address + 4096 + i * 2] = 0x23;
                state->vram_ptr[dma_a.address + 4097 + i * 2] = 0xb7;
            }
            NV2AMetalPGRAPHTextureSnapshot *snapshot = prepare();
            id<MTLTexture> texture =
                [snapshot textureAtIndex:0].binding.texture;
            assert(texture.width == width &&
                   texture.mipmapLevelCount == levels);
            assert(texture.textureType == (layout == 1 ? MTLTextureTypeCube :
                                           layout == 2 ? MTLTextureType3D :
                                                         MTLTextureType2D));
            NV2AMetalPixelUniforms u = { 0 };
            NV2AMetalPixelTexture bindings[4];
            require([snapshot applyToUniforms:&u
                                     textures:bindings
                                        error:&error],
                    error);
            assert(u.textures[0].rectangle == (f & 1));
            id<MTLBuffer> out = read_texture(snapshot, 0);
            finish();
            require([snapshot validateCompletedWithError:&error], error);
            assert(texture.pixelFormat == (f < 2 ? MTLPixelFormatR32Float :
                                                   MTLPixelFormatB5G6R5Unorm));
            if (f < 2)
                pixel(out, width, 0, 0, 1, 46883.0f / 65535, 46883.0f / 65535,
                      1);
            else
                pixel(out, width, 0, 0, (0xb723 >> 11) / 31.f,
                      ((0xb723 >> 5) & 63) / 63.f, (0xb723 & 31) / 31.f, 1);
            stage_roundtrip(snapshot);
            checks++;
        }
    }
}
static unsigned signed_morton(unsigned x, unsigned y, unsigned z, unsigned w,
                              unsigned d);
static void hilo16_register_tests(void)
{
    NSError *error = nil;
    const unsigned formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16
    };
    unsigned cases = 0, texels = 0;
    for (unsigned f = 0; f < 2; f++)
        for (unsigned stage = 0; stage < 4; stage++)
            for (unsigned kind = 0; kind < (f ? 1 : 3); kind++) {
                PGRAPHState *pg = &state->pgraph;
                for (unsigned i = 0; i < 4; i++)
                    pg->regs_[NV_PGRAPH_TEXCTL0_0 + i * 4] = 0;
                registers(stage, formats[f], 4, 32, 4096, false);
                if (kind == 1)
                    pg->regs_[NV_PGRAPH_TEXFMT0 + stage * 4] |=
                        NV_PGRAPH_TEXFMT0_CUBEMAPENABLE;
                if (kind == 2) {
                    pg->regs_[NV_PGRAPH_TEXFMT0 + stage * 4] &=
                        ~NV_PGRAPH_TEXFMT0_DIMENSIONALITY;
                    pg->regs_[NV_PGRAPH_TEXFMT0 + stage * 4] |=
                        3 << 6 | 2 << 28;
                }
                unsigned faces = kind == 1 ? 6 : 1, depth = kind == 2 ? 4 : 1;
                unsigned length = f         ? 128 :
                                  kind == 1 ? 128 * faces :
                                              64 * depth;
                cpu_write(8192, length);
                for (unsigned i = 0; i < length; i += 4) {
                    uint32_t word = 0x1289e237 ^ (i / 4 * 0x10003u);
                    stl_le_p(state->vram_ptr + 8192 + i, word);
                }
                NV2AMetalPGRAPHTextureSnapshot *snapshot = prepare();
                NV2AMetalPixelUniforms u = { 0 };
                NV2AMetalPixelTexture bindings[4] = {};
                require([snapshot applyToUniforms:&u
                                         textures:bindings
                                            error:&error],
                        error);
                assert(u.hilo16_mask == (1u << stage) &&
                       u.textures[stage].rectangle == f);
                for (unsigned face = 0; face < faces; face++) {
                    id<MTLBuffer> out =
                        read_subresource(bindings[stage].texture, 0, face);
                    finish();
                    for (unsigned z = 0; z < depth; z++)
                        for (unsigned y = 0; y < 4; y++)
                            for (unsigned x = 0; x < 4; x++) {
                                unsigned index =
                                    f ? y * 8 + x :
                                        face * 32 +
                                            signed_morton(x, y, z, 4, depth);
                                uint32_t word = 0x1289e237 ^ (index * 0x10003u);
                                float hi = (float)((word >> 16) / 65535.0),
                                      lo = (float)((word & 65535) / 65535.0);
                                pixel(out, 4, x, y + z * 4, hi, lo, lo, 1);
                                texels++;
                            }
                }
                NSData *wire = [snapshot snapshotWithCommands:surfaces.commands
                                                        error:&error];
                require(wire != nil, error);
                assert(ldl_be_p((const uint8_t *)wire.bytes + 4) == 3);
                for (unsigned old_version = 1; old_version <= 2;
                     old_version++) {
                    NSMutableData *bad = [wire mutableCopy];
                    stl_be_p((uint8_t *)bad.mutableBytes + 4, old_version);
                    assert(![NV2AMetalPGRAPHTextureSnapshot
                        validateSnapshot:bad
                                   error:NULL]);
                }
                NV2AMetalPixelUniforms wrong = u;
                wrong.hilo16_mask ^= 1u << stage;
                assert(![NV2AMetalPGRAPHTextureSnapshot validateSnapshot:wire
                                                                uniforms:&wrong
                                                                   error:NULL]);
                stage_roundtrip(snapshot);
                cases++;
            }
    assert(cases == 16 && texels == 768);
    printf("Metal4 HILO16 PGRAPH: %u stage/layout/type captures and restores "
           "PASS\n",
           cases);
}

static void signed_register_tests(void)
{
    PGRAPHState *pg = &state->pgraph;
    const unsigned bits[] = { NV_PGRAPH_TEXFILTER0_RSIGNED,
                              NV_PGRAPH_TEXFILTER0_GSIGNED,
                              NV_PGRAPH_TEXFILTER0_BSIGNED,
                              NV_PGRAPH_TEXFILTER0_ASIGNED };
    const unsigned formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8
    };
    const unsigned raw[4][4] = { { 127, 128, 255, 1 },
                                 { 255, 128, 127, 1 },
                                 { 128, 127, 1, 255 },
                                 { 1, 127, 128, 255 } };
    for (unsigned format = 0; format < 8; format++) {
        for (unsigned stage = 0; stage < 4; stage++) {
            for (unsigned j = 0; j < 4; j++)
                pg->regs_[NV_PGRAPH_TEXCTL0_0 + 4 * j] = 0;
            registers(stage, formats[format], 4, 16, 1024 + 64 * stage, false);
            NSUInteger address = dma_a.address + 1024 + 64 * stage;
            NSError *error = nil;
            require([surfaces prepareCPUAccessAtAddress:address
                                                 length:64
                                                  write:YES
                                                  error:&error],
                    error);
            for (unsigned j = 0; j < 16; j++) {
                uint32_t color = 0x017f80ff;
                memcpy(state->vram_ptr + address + j * 4, &color, 4);
            }
            for (unsigned mask = 0; mask < 16; mask++) {
                pg->regs_[NV_PGRAPH_TEXFILTER0 + stage * 4] = 1 << 16 | 1 << 24;
                for (unsigned k = 0; k < 4; k++) {
                    if (mask & (1u << k))
                        pg->regs_[NV_PGRAPH_TEXFILTER0 + stage * 4] |= bits[k];
                }
                NV2AMetalPGRAPHTextureSnapshot *snapshot = prepare();
                NV2AMetalPixelUniforms u = { 0 };
                NV2AMetalPixelTexture textures[4] = { 0 };
                require([snapshot applyToUniforms:&u
                                         textures:textures
                                            error:&error],
                        error);
                assert(u.textures[stage].signed_channels == mask &&
                       u.textures[stage].snorm ==
                           (mask && mask != 15 ?
                                NV2AMetalTextureNormalizationMixedHalf :
                                0));
                id<MTLBuffer> out = read_texture(snapshot, stage);
                finish();
                float expected[4];
                for (unsigned k = 0; k < 4; k++) {
                    int code = raw[format / 2][k];
                    if ((mask & (1u << k)) && code >= 128)
                        code -= 256;
                    expected[k] = code / ((mask & (1u << k)) ? 128.0f : 255.0f);
                }
                for (unsigned y = 0; y < 4; y++) {
                    for (unsigned x = 0; x < 4; x++) {
                        pixel(out, 4, x, y, expected[0], expected[1],
                              expected[2], expected[3]);
                    }
                }
                stage_roundtrip(snapshot);
                NSData *saved = [snapshot snapshotWithCommands:surfaces.commands
                                                         error:&error];
                require(saved != nil, error);
                NV2AMetalPGRAPHTextureSnapshot *restored =
                    [[NV2AMetalPGRAPHTextureSnapshot alloc]
                        initWithSnapshot:saved
                                commands:surfaces.commands
                                   error:&error];
                require(restored != nil, error);
                out = read_texture(restored, stage);
                finish();
                for (unsigned y = 0; y < 4; y++) {
                    for (unsigned x = 0; x < 4; x++) {
                        pixel(out, 4, x, y, expected[0], expected[1],
                              expected[2], expected[3]);
                    }
                }
            }
        }
    }
    for (unsigned j = 0; j < 4; j++)
        pg->regs_[NV_PGRAPH_TEXCTL0_0 + j * 4] = 0;
    checks++;
    printf("Metal4 signed8 PGRAPH: 512 format/mask/stage captures, v3 "
           "roundtrips and 16384 original/restored texels PASS\n");
}

static unsigned signed_subresource_texels, signed_sampler_pixels;

static unsigned signed_morton(unsigned x, unsigned y, unsigned z, unsigned w,
                              unsigned d)
{
    unsigned result = 0, output_bit = 1;
    for (unsigned bit = 1; bit < w || bit < d; bit <<= 1) {
        const unsigned coordinate[] = { x, y, z };
        const unsigned size[] = { w, w, d };
        for (unsigned axis = 0; axis < 3; axis++) {
            if (bit < size[axis]) {
                if (coordinate[axis] & bit)
                    result |= output_bit;
                output_bit <<= 1;
            }
        }
    }
    return result;
}

static void signed_expected(unsigned format, unsigned mask, unsigned level,
                            unsigned face, unsigned x, unsigned y, unsigned z,
                            BOOL transfer, float expected[4])
{
    const unsigned channel[4][4] = {
        { 2, 1, 0, 3 }, { 0, 1, 2, 3 }, { 1, 2, 3, 0 }, { 3, 2, 1, 0 }
    };
    for (unsigned k = 0; k < 4; k++) {
        int code = (17 + 13 * x + 23 * y + 37 * z + 43 * level + 59 * face +
                    71 * channel[format][k]) &
                   255;
        if (mask & (1u << k)) {
            if (code >= 128)
                code -= 256;
            expected[k] = code / (transfer ? 127.5f : 128.0f);
        } else {
            expected[k] = code / 255.0f;
        }
    }
}

static void signed_sample(NV2AMetalPGRAPHTextureSnapshot *snapshot,
                          NV2AMetalPixelShader *shader, unsigned stage,
                          unsigned kind, unsigned format, unsigned mask,
                          unsigned base_level)
{
    NSError *error = nil;
    require([surfaces prepareGPUReadAtAddress:0 length:0 error:&error], error);
    NV2AMetalPixelUniforms u = { 0 };
    NV2AMetalPixelTexture textures[4] = { 0 };
    require([snapshot applyToUniforms:&u textures:textures error:&error],
            error);
    unsigned faces = kind == 2 ? 6 : 1, width = 4 * faces;
    unsigned mode = kind == 1 ? PS_TEXTUREMODES_PROJECT3D :
                    kind == 2 ? PS_TEXTUREMODES_CUBEMAP :
                                PS_TEXTUREMODES_PROJECT2D;
    u.combiner.shader_stage_program = mode << (5 * stage);
    unsigned input = (PS_REGISTER_T0 + stage) | PS_INPUTMAPPING_SIGNED_IDENTITY;
    u.combiner.final_inputs[0] = input;
    u.combiner.final_inputs[1] = (input | PS_CHANNEL_ALPHA) << 8;
    u.surface_scale[0] = u.surface_scale[1] = 1;
    u.clip_range[1] = u.clip_range[3] = 65535;
    u.clip_regions[0][2] = width;
    u.clip_regions[0][3] = 4;
    id<MTLTexture> sampled = textures[stage].texture;
    float uv = 1.0f / sampled.width - 1;
    /* Directions select the centre of texel (0,0) on each GL cube face. */
    const float direction[6][3] = { { 1, -uv, -uv }, { -1, -uv, uv },
                                    { uv, 1, uv },   { uv, -1, -uv },
                                    { uv, -uv, 1 },  { -uv, -uv, -1 } };
    NV2AMetalVertex vertices[36] = { 0 };
    const unsigned xy[6][2] = { { 0, 0 }, { 4, 0 }, { 0, 4 },
                                { 4, 0 }, { 4, 4 }, { 0, 4 } };
    for (unsigned face = 0; face < faces; face++) {
        for (unsigned j = 0; j < 6; j++) {
            NV2AMetalVertex *v = &vertices[6 * face + j];
            v->clip[0] = 2.0f * (face * 4 + xy[j][0]) / width - 1;
            v->clip[1] = 1 - xy[j][1] / 2.0f;
            v->clip[2] = .5f;
            v->clip[3] = 1;
            for (unsigned k = 0; k < 3; k++)
                v->texcoord[stage][k] =
                    kind == 2 ? direction[face][k] : .5f / sampled.width;
            v->texcoord[stage][3] = 1;
            v->plane[0][2] = v->plane[1][2] = v->plane[2][2] = .5f;
        }
    }
    id<MTLBuffer> input_vertices = [surfaces.commands.device
        newBufferWithBytes:vertices
                    length:faces * 6 * sizeof(vertices[0])
                   options:MTLResourceStorageModeShared];
    assert(input_vertices);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:width
                                    height:4
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target =
        [surfaces.commands.device newTextureWithDescriptor:td];
    assert(target);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    require([shader encodeVertices:input_vertices
                             count:faces * 6
                         primitive:MTLPrimitiveTypeTriangle
                          uniforms:&u
                          textures:textures
                              pass:pass
                      depthStencil:nil
                          commands:surfaces.commands
                             error:&error],
            error);
    id<MTLBuffer> out = read_subresource(target, 0, 0);
    id<MTLBuffer> referenceOut = nil;
    NV2AMetalPixelUniforms preserved = u;
    if (sampled.pixelFormat == MTLPixelFormatRGBA16Float) {
        id<MTLTexture> reference = test_metal_float_reference_decoded(
            surfaces.commands, sampled,
            u.textures[stage].snorm == NV2AMetalTextureNormalizationMixedHalf ?
                (15u ^ mask) :
                0);
        NV2AMetalPixelUniforms referenceU = u;
        referenceU.textures[stage].snorm = 0;
        textures[stage].texture = reference;
        require([shader encodeVertices:input_vertices
                                 count:faces * 6
                             primitive:MTLPrimitiveTypeTriangle
                              uniforms:&referenceU
                              textures:textures
                                  pass:pass
                          depthStencil:nil
                              commands:surfaces.commands
                                 error:&error],
                error);
        referenceOut = read_subresource(target, 0, 0);
    }
    assert(!memcmp(&preserved, &u, sizeof(u)));
    finish();
    if (referenceOut) {
        NSUInteger row = (width * 16 + 255) & ~(NSUInteger)255;
        for (unsigned y = 0; y < 4; y++)
            assert(!memcmp((const char *)out.contents + y * row,
                           (const char *)referenceOut.contents + y * row,
                           width * 16));
    }
    for (unsigned face = 0; face < faces; face++) {
        float expected[4];
        signed_expected(format, mask, base_level, face, 0, 0, 0, YES, expected);
        for (unsigned y = 0; y < 4; y++) {
            for (unsigned x = 0; x < 4; x++) {
                pixel(out, width, face * 4 + x, y, expected[0], expected[1],
                      expected[2], expected[3]);
                signed_sampler_pixels++;
            }
        }
    }
}

static void signed_readback(NV2AMetalPGRAPHTextureSnapshot *snapshot,
                            unsigned stage, unsigned kind, unsigned size,
                            unsigned levels, unsigned base, unsigned format,
                            unsigned mask)
{
    NSError *error = nil;
    unsigned faces = kind == 2 ? 6 : 1;
    id<MTLTexture> t = [snapshot textureAtIndex:stage].binding.texture;
    assert(t.width == size >> base && t.height == size >> base &&
           t.depth == (kind == 1 ? size >> base : 1) &&
           t.mipmapLevelCount == levels - base &&
           t.textureType == (kind == 1 ? MTLTextureType3D :
                             kind == 2 ? MTLTextureTypeCube :
                                         MTLTextureType2D));
    require([surfaces prepareGPUReadAtAddress:0 length:0 error:&error], error);
    NSMutableArray<id<MTLBuffer>> *out = [NSMutableArray new];
    for (unsigned face = 0; face < faces; face++) {
        for (unsigned level = 0; level < levels - base; level++)
            [out addObject:test_metal_read_texture_decoded(
                               surfaces.commands, t, level, face,
                               [snapshot textureAtIndex:stage].mixedSignedHalf ?
                                   (15u ^ mask) :
                                   0)];
    }
    finish();
    require([snapshot validateCompletedWithError:&error], error);
    for (unsigned face = 0; face < faces; face++) {
        for (unsigned level = base; level < levels; level++) {
            unsigned w = size >> level, d = kind == 1 ? w : 1;
            id<MTLBuffer> data = out[face * (levels - base) + level - base];
            NSUInteger row = (w * 16 + 255) & ~255u;
            for (unsigned z = 0; z < d; z++) {
                for (unsigned y = 0; y < w; y++) {
                    for (unsigned x = 0; x < w; x++) {
                        const float *p =
                            (const float *)((const char *)data.contents +
                                            (z * w + y) * row + x * 16);
                        float expected[4];
                        signed_expected(format, mask, level, face, x, y, z, NO,
                                        expected);
                        for (unsigned k = 0; k < 4; k++) {
                            if (!isfinite(p[k]) ||
                                fabsf(p[k] - expected[k]) >= .000001f) {
                                fprintf(
                                    stderr,
                                    "Signed PGRAPH kind %u face %u level %u "
                                    "xyz %u/%u/%u channel %u: %g expected %g\n",
                                    kind, face, level, x, y, z, k, p[k],
                                    expected[k]);
                                abort();
                            }
                        }
                        signed_subresource_texels++;
                    }
                }
            }
        }
    }
}

static void signed_subresource_tests(void)
{
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    const unsigned formats[] = { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8,
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8,
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8,
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8 };
    const unsigned bits[] = { NV_PGRAPH_TEXFILTER0_RSIGNED,
                              NV_PGRAPH_TEXFILTER0_GSIGNED,
                              NV_PGRAPH_TEXFILTER0_BSIGNED,
                              NV_PGRAPH_TEXFILTER0_ASIGNED };
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:surfaces.commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    unsigned captures = 0;
    for (unsigned format = 0; format < 4; format++) {
        for (unsigned kind = 0; kind < 3; kind++) {
            unsigned size = kind == 1 ? 8 : 4;
            unsigned levels = kind == 1 ? 2 : 3;
            unsigned faces = kind == 2 ? 6 : 1;
            unsigned stride = kind == 1 ? 2304 : kind == 2 ? 128 : 84;
            unsigned char bytes[2304];
            memset(bytes, 0xa5, sizeof(bytes));
            for (unsigned face = 0; face < faces; face++) {
                unsigned offset = face * stride;
                for (unsigned level = 0; level < levels; level++) {
                    unsigned w = size >> level, d = kind == 1 ? w : 1;
                    for (unsigned z = 0; z < d; z++) {
                        for (unsigned y = 0; y < w; y++) {
                            for (unsigned x = 0; x < w; x++) {
                                unsigned at =
                                    offset + 4 * signed_morton(x, y, z, w, d);
                                for (unsigned k = 0; k < 4; k++)
                                    bytes[at + k] =
                                        (17 + 13 * x + 23 * y + 37 * z +
                                         43 * level + 59 * face + 71 * k) &
                                        255;
                            }
                        }
                    }
                    offset += 4 * w * w * d;
                }
            }
            for (unsigned stage = 0; stage < 4; stage++) {
                for (unsigned j = 0; j < 4; j++)
                    pg->regs_[NV_PGRAPH_TEXCTL0_0 + 4 * j] = 0;
                NSUInteger address =
                    (stage & 1 ? dma_b.address : dma_a.address) + 16384;
                cpu_write(address, faces * stride);
                memcpy(state->vram_ptr + address, bytes, faces * stride);
                for (unsigned mask = 0; mask < 16; mask++) {
                    for (unsigned base = 0; base < 2; base++) {
                        @autoreleasepool {
                            registers(stage, formats[format], size, 0, 16384,
                                      stage & 1);
                            pg->regs_[NV_PGRAPH_TEXFMT0 + 4 * stage] =
                                NV_PGRAPH_TEXFMT0_BORDER_SOURCE |
                                (formats[format] << 8) |
                                ((kind == 1 ? 3 : 2) << 6) | (levels << 16) |
                                ((kind == 1 ? 3 : 2) << 20) |
                                ((kind == 1 ? 3 : 2) << 24) |
                                ((kind == 1 ? 3u : 0u) << 28) |
                                (kind == 2 ? NV_PGRAPH_TEXFMT0_CUBEMAPENABLE :
                                             0) |
                                (stage & 1 ? NV_PGRAPH_TEXFMT0_CONTEXT_DMA : 0);
                            pg->regs_[NV_PGRAPH_TEXCTL0_0 + 4 * stage] |=
                                ((levels - 1) << 6) | (base << 18);
                            pg->regs_[NV_PGRAPH_TEXFILTER0 + 4 * stage] =
                                2 << 16 | 2 << 24;
                            for (unsigned k = 0; k < 4; k++) {
                                if (mask & (1u << k))
                                    pg->regs_[NV_PGRAPH_TEXFILTER0 +
                                              4 * stage] |= bits[k];
                            }
                            NV2AMetalPGRAPHTextureSnapshot *original =
                                prepare();
                            finish();
                            NSData *saved =
                                [original snapshotWithCommands:surfaces.commands
                                                         error:&error];
                            require(saved != nil, error);
                            [adapter flush];
                            NV2AMetalPGRAPHTextureSnapshot *restored =
                                [[NV2AMetalPGRAPHTextureSnapshot alloc]
                                    initWithSnapshot:saved
                                            commands:surfaces.commands
                                               error:&error];
                            require(restored != nil, error);
                            NSData *again =
                                [restored snapshotWithCommands:surfaces.commands
                                                         error:&error];
                            require(again != nil, error);
                            for (NV2AMetalPGRAPHTextureSnapshot *snapshot in
                                 @[ original, restored ]) {
                                signed_readback(snapshot, stage, kind, size,
                                                levels, base, format, mask);
                                signed_sample(snapshot, shader, stage, kind,
                                              format, mask, base);
                            }
                            assert([saved isEqualToData:again]);
                            captures++;
                        }
                    }
                }
            }
        }
    }
    for (unsigned j = 0; j < 4; j++)
        pg->regs_[NV_PGRAPH_TEXCTL0_0 + 4 * j] = 0;
    assert(captures == 1536 && signed_subresource_texels == 420864 &&
           signed_sampler_pixels == 131072);
    checks++;
    printf("Metal4 signed8 PGRAPH subresources: 1536 captures/restores, "
           "420864 original/restored texels, 3072 sampler/combiner draws/"
           "131072 pixels; four formats/16 masks/four stages/2D/3D/cube/"
           "base0+1 PASS\n");
}

static void hilo16_brdf_register_tests(void)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:surfaces.commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    const uint32_t pairs[][2] = { { 0x30001000, 0xd0007000 },
                                  { 0x1289e237, 0xabe36519 },
                                  { 0x0102ff00, 0xfefd00ff },
                                  { 0x80800101, 0x7f7ffefe } };
    unsigned draws = 0;
    for (unsigned pair = 0; pair < 4; pair++)
        for (unsigned reverse = 0; reverse < 2; reverse++)
            for (unsigned linear = 0; linear < 2; linear++)
                for (unsigned stage = 2; stage <= 3; stage++) {
                    uint32_t eye = pairs[pair][reverse],
                             light = pairs[pair][!reverse];
                    PGRAPHState *pg = &state->pgraph;
                    pg->regs_[NV_PGRAPH_SHADERPROG] = 0;
                    for (unsigned i = 0; i < 4; i++)
                        pg->regs_[NV_PGRAPH_TEXCTL0_0 + i * 4] = 0;
                    for (unsigned i = stage - 2; i < stage; i++) {
                        unsigned offset = i == stage - 2 ? 4096 : 8192;
                        unsigned format =
                            linear ?
                                NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16 :
                                NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16;
                        registers(i, format, 4, 32, offset, false);
                        if (!linear) {
                            pg->regs_[NV_PGRAPH_TEXFMT0 + i * 4] |=
                                NV_PGRAPH_TEXFMT0_CUBEMAPENABLE;
                            pg->regs_[NV_PGRAPH_SHADERPROG] &=
                                ~(31u << (5 * i));
                            pg->regs_[NV_PGRAPH_SHADERPROG] |=
                                PS_TEXTUREMODES_CUBEMAP << (5 * i);
                        }
                        unsigned length = linear ? 128 : 768;
                        cpu_write(4096 + offset, length);
                        for (unsigned j = 0; j < length; j += 4)
                            stl_le_p(state->vram_ptr + 4096 + offset + j,
                                     i == stage - 2 ? eye : light);
                    }
                    registers(stage, NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8,
                              4, 0, 16384, false);
                    pg->regs_[NV_PGRAPH_TEXFMT0 + stage * 4] &=
                        ~NV_PGRAPH_TEXFMT0_DIMENSIONALITY;
                    pg->regs_[NV_PGRAPH_TEXFMT0 + stage * 4] |=
                        3 << 6 | 2 << 28;
                    pg->regs_[NV_PGRAPH_TEXADDRESS0 + stage * 4] =
                        3 | 3 << 8 | 1 << 16;
                    pg->regs_[NV_PGRAPH_SHADERPROG] &= ~(31u << (5 * stage));
                    pg->regs_[NV_PGRAPH_SHADERPROG] |= PS_TEXTUREMODES_BRDF
                                                       << (5 * stage);
                    cpu_write(20480, 256);
                    for (unsigned z = 0; z < 4; z++)
                        for (unsigned y = 0; y < 4; y++)
                            for (unsigned x = 0; x < 4; x++) {
                                uint32_t color =
                                    0xff000000 | (17 + 32 * x) << 16 |
                                    (33 + 32 * y) << 8 | (49 + 32 * z);
                                stl_le_p(state->vram_ptr + 20480 +
                                             4 * signed_morton(x, y, z, 4, 4),
                                         color);
                            }
                    NV2AMetalPGRAPHTextureSnapshot *original = prepare();
                    NV2AMetalPixelUniforms frozen = { 0 };
                    NV2AMetalPixelTexture bindings[4];
                    require([original applyToUniforms:&frozen
                                             textures:bindings
                                                error:&error],
                            error);
                    assert(frozen.hilo16_mask == (3u << (stage - 2)));
                    frozen.combiner.shader_stage_program =
                        pg->regs_[NV_PGRAPH_SHADERPROG];
                    frozen.combiner.final_inputs[0] = PS_REGISTER_T0 + stage;
                    frozen.combiner.final_inputs[1] =
                        (PS_REGISTER_T0 + stage | PS_CHANNEL_ALPHA) << 8;
                    frozen.surface_scale[0] = frozen.surface_scale[1] = 1;
                    frozen.clip_range[1] = frozen.clip_range[3] = 65535;
                    frozen.clip_regions[0][2] = frozen.clip_regions[0][3] = 4;
                    finish();
                    NSData *wire =
                        [original snapshotWithCommands:surfaces.commands
                                                 error:&error];
                    require(wire != nil, error);
                    cpu_write(8192, 24576 - 8192);
                    memset(state->vram_ptr + 8192, 0x5b, 24576 - 8192);
                    pg->regs_[NV_PGRAPH_SHADERPROG] = UINT32_MAX;
                    NV2AMetalPGRAPHTextureSnapshot *restored =
                        [[NV2AMetalPGRAPHTextureSnapshot alloc]
                            initWithSnapshot:wire
                                    commands:surfaces.commands
                                       error:&error];
                    require(restored != nil, error);
                    for (NV2AMetalPGRAPHTextureSnapshot *snapshot in
                         @[ original, restored ]) {
                        NV2AMetalPixelUniforms u = frozen;
                        require([snapshot applyToUniforms:&u
                                                 textures:bindings
                                                    error:&error],
                                error);
                        require([NV2AMetalPGRAPHTextureSnapshot
                                    validateSnapshot:wire
                                            uniforms:&u
                                               error:&error],
                                error);
                        NV2AMetalVertex vertices[6] = {};
                        const float xy[][2] = { { -1, 1 },  { 1, 1 },
                                                { -1, -1 }, { 1, 1 },
                                                { 1, -1 },  { -1, -1 } };
                        for (unsigned j = 0; j < 6; j++) {
                            vertices[j].clip[0] = xy[j][0];
                            vertices[j].clip[1] = xy[j][1];
                            vertices[j].clip[3] = 1;
                            const float plane[3][4] = { { 0, 0, .5f, 1 },
                                                        { 4, 0, .5f, 1 },
                                                        { 0, 4, .5f, 1 } };
                            memcpy(vertices[j].plane, plane, sizeof(plane));
                            for (unsigned i = stage - 2; i < stage; i++) {
                                vertices[j].texcoord[i][0] = linear ? .5f : 1;
                                vertices[j].texcoord[i][1] = .25f;
                                vertices[j].texcoord[i][2] = -.5f;
                                vertices[j].texcoord[i][3] = 1;
                            }
                        }
                        id<MTLBuffer> input = [surfaces.commands.device
                            newBufferWithBytes:vertices
                                        length:sizeof(vertices)
                                       options:MTLResourceStorageModeShared];
                        MTLTextureDescriptor *td = [MTLTextureDescriptor
                            texture2DDescriptorWithPixelFormat:
                                MTLPixelFormatRGBA32Float
                                                         width:4
                                                        height:4
                                                     mipmapped:NO];
                        td.storageMode = MTLStorageModePrivate;
                        td.usage = MTLTextureUsageRenderTarget;
                        id<MTLTexture> target = [surfaces.commands.device
                            newTextureWithDescriptor:td];
                        assert(input && target);
                        MTL4RenderPassDescriptor *pass =
                            [MTL4RenderPassDescriptor new];
                        pass.colorAttachments[0].texture = target;
                        pass.colorAttachments[0].loadAction =
                            MTLLoadActionClear;
                        pass.colorAttachments[0].storeAction =
                            MTLStoreActionStore;
                        require([surfaces prepareGPUReadAtAddress:0
                                                           length:0
                                                            error:&error],
                                error);
                        require([shader encodeVertices:input
                                                 count:6
                                             primitive:MTLPrimitiveTypeTriangle
                                              uniforms:&u
                                              textures:bindings
                                                  pass:pass
                                          depthStencil:nil
                                              commands:surfaces.commands
                                                 error:&error],
                                error);
                        id<MTLBuffer> out = read_subresource(target, 0, 0);
                        finish();
                        unsigned x = MIN(3u, (unsigned)floor((eye >> 16) /
                                                             65535.0 * 4)),
                                 y = MIN(3u, (unsigned)floor((light >> 16) /
                                                             65535.0 * 4));
                        int z = (int)floor(
                            ((int)(light & 65535) - (int)(eye & 65535)) /
                            65535.0 * 4);
                        z = (z % 4 + 4) % 4;
                        for (unsigned py = 0; py < 4; py++)
                            for (unsigned px = 0; px < 4; px++)
                                pixel(out, 4, px, py, (17 + 32 * x) / 255.f,
                                      (33 + 32 * y) / 255.f,
                                      (49 + 32 * z) / 255.f, 1);
                        draws++;
                    }
                }
    assert(draws == 64);
    printf("Metal4 HILO16 BRDF PGRAPH:32 captures/32 restores/64 draws/1024 "
           "pixels PASS\n");
}

static uint32_t hilo16_filter_word(unsigned x, unsigned y, unsigned level)
{
    const uint32_t words[] = { 0x1289e237, 0xabe36519, 0x00ff7fff, 0x01008000,
                               0x7ffffffe, 0x80000001, 0xfeff0102, 0xff0000ff,
                               0,          UINT32_MAX, 0x80800101, 0x7f7ffefe,
                               0x0102ff00, 0xfefd00ff, 0x55aa3322, 0xaa557766 };
    return words[(x + 3 * y + 5 * level) % ARRAY_SIZE(words)];
}
static double hilo16_filter_component(int x, int y, unsigned level,
                                      unsigned address, unsigned channel,
                                      BOOL signedHILO)
{
    int width = 8 >> level;
    if (address == 1) {
        x = (x % width + width) % width;
        y = (y % width + width) % width;
    } else if (address == 4 && (x < 0 || y < 0 || x >= width || y >= width)) {
        int raw = channel == 0 ? 0x12 : 0x89;
        return signedHILO ? (raw >= 128 ? raw - 256 : raw) / 128.0 :
                            raw / 255.0;
    } else {
        x = MAX(0, MIN(width - 1, x));
        y = MAX(0, MIN(width - 1, y));
    }
    uint32_t word = hilo16_filter_word(x, y, level);
    int raw = channel == 0 ? word >> 16 : word & 65535;
    return signedHILO ? (raw >= 32768 ? raw - 65536 : raw) / 32768.0 :
                        raw / 65535.0;
}
static double hilo16_filter_level(double s, double t, unsigned level,
                                  unsigned address, bool linear,
                                  unsigned channel, BOOL signedHILO)
{
    double c[] = { s, t };
    for (unsigned axis = 0; axis < 2; axis++) {
        if (address == 1)
            c[axis] -= floor(c[axis]);
        if (address == 2) {
            c[axis] = fmod(c[axis], 2);
            if (c[axis] < 0)
                c[axis] += 2;
            if (c[axis] > 1)
                c[axis] = 2 - c[axis];
        }
    }
    unsigned width = 8 >> level;
    double x = c[0] * width, y = c[1] * width;
    if (!linear)
        return hilo16_filter_component(floor(x), floor(y), level, address,
                                       channel, signedHILO);
    x -= .5;
    y -= .5;
    int left = floor(x), top = floor(y);
    double fx = x - left, fy = y - top;
    double a = hilo16_filter_component(left, top, level, address, channel,
                                       signedHILO),
           b = hilo16_filter_component(left + 1, top, level, address, channel,
                                       signedHILO),
           c0 = hilo16_filter_component(left, top + 1, level, address, channel,
                                        signedHILO),
           d = hilo16_filter_component(left + 1, top + 1, level, address,
                                       channel, signedHILO);
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c0 * (1 - fx) + d * fx) * fy;
}
static double hilo16_filter_reference(double s, double t, double dx, double dy,
                                      double lod, unsigned taps, unsigned first,
                                      unsigned last, unsigned address,
                                      unsigned min, unsigned mag,
                                      unsigned channel, BOOL signedHILO)
{
    bool linear = lod <= 0 ? mag == 2 : min % 2 == 0;
    double l = min < 3 ? 0 : MAX(0, MIN((double)(last - first), lod));
    unsigned low = 0, high = 0;
    double blend = 0;
    if (min >= 5) {
        low = floor(l);
        high = MIN(low + 1, last - first);
        blend = l - low;
    } else if (min >= 3) {
        // Choose the closest level; an exact half-distance retains the lower.
        for (unsigned i = 1; i <= last - first; i++)
            if (fabs(l - i) < fabs(l - low))
                low = i;
        high = low;
    }
    double sum = 0;
    for (unsigned i = 0; i < taps; i++) {
        double offset = ((double)i + 1) / (taps + 1) - .5;
        double u = s + offset * dx, v = t;
        // The test presets use an S major axis, or equal S/T footprints.
        if (dx == dy) {
            u = s;
            v += offset * dy;
        }
        double a = hilo16_filter_level(u, v, first + low, address, linear,
                                       channel, signedHILO),
               b = hilo16_filter_level(u, v, first + high, address, linear,
                                       channel, signedHILO);
        sum += a * (1 - blend) + b * blend;
    }
    return sum / taps;
}
static void hilo16_input_filter_tests(BOOL signedHILO)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:surfaces.commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:8
                                    height:8
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target =
        [surfaces.commands.device newTextureWithDescriptor:td];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> lookup =
        [surfaces.commands.device newTextureWithDescriptor:td];
    float gradient[8][8][4];
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            gradient[y][x][0] = (x + .5f) / 8;
            gradient[y][x][1] = (y + .5f) / 8;
            gradient[y][x][2] = .2f;
            gradient[y][x][3] = .75f;
        }
    assert(target && lookup);
    [lookup replaceRegion:MTLRegionMake2D(0, 0, 8, 8)
              mipmapLevel:0
                withBytes:gradient
              bytesPerRow:sizeof(gradient[0])];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> sampler =
        [surfaces.commands.device newSamplerStateWithDescriptor:sd];
    assert(sampler);
    // Footprints are specified in texels of the bound view. LOD and tap counts
    // below are independently fixed for these analytic axis-aligned cases.
    const struct {
        double major, minor, lod, s, t;
        int bias;
        unsigned taps;
    } profiles[] = { { 0, 0, -100, .5, .5, 0, 1 },
                     { 0, 0, -100, .125, .375, 0, 1 },
                     { 1, 1, .5, -.03125, .03125, 128, 1 },
                     { 1, 1, .75, 1.03125, -.03125, 192, 1 },
                     { 1.5, 1, .5849625007211562, .484375, .515625, 0, 1 },
                     { 8, 1, 3, .5, .5, 0, 1 },
                     { 8, 1, 2, .5, .5, 0, 2 },
                     { 8, 1, 1, .5, .5, 0, 4 },
                     { 8, 1, 0, .5, .5, 0, 8 },
                     { 1, 1, -.5, .515625, .484375, -128, 1 } };
    const unsigned ranges[][2] = { { 0, 3 }, { 1, 3 }, { 0, 2 }, { 2, 2 } };
    unsigned captures = 0, draws = 0, channels = 0, eightTapDraws = 0,
             rawTexels = 0;
    for (unsigned rect = 0; rect < 2; rect++)
        for (unsigned range = 0; range < (rect ? 1u : 4u); range++)
            for (unsigned min = 1; min <= 6; min++)
                for (unsigned mag = 1; mag <= 2; mag++)
                    for (unsigned address = 1; address <= 5; address++)
                        for (unsigned profile = 0;
                             profile < ARRAY_SIZE(profiles); profile++) {
                            @autoreleasepool {
                                PGRAPHState *pg = &state->pgraph;
                                for (unsigned i = 0; i < 4; i++)
                                    pg->regs_[NV_PGRAPH_TEXCTL0_0 + i * 4] = 0;
                                pg->regs_[NV_PGRAPH_SHADERPROG] = 0;
                                registers(
                                    0,
                                    rect ?
                                        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16 :
                                        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16,
                                    8, 48, 4096, false);
                                unsigned first = rect ? 0 : ranges[range][0],
                                         last = rect ? 0 : ranges[range][1];
                                uint32_t *fmt = &pg->regs_[NV_PGRAPH_TEXFMT0];
                                SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_BASE_SIZE_U,
                                         3);
                                SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_BASE_SIZE_V,
                                         3);
                                SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_MIPMAP_LEVELS,
                                         4);
                                pg->regs_[NV_PGRAPH_TEXIMAGERECT0] =
                                    8 << 16 | 8;
                                uint32_t *ctl = &pg->regs_[NV_PGRAPH_TEXCTL0_0];
                                SET_MASK(*ctl,
                                         NV_PGRAPH_TEXCTL0_0_MIN_LOD_CLAMP,
                                         first);
                                SET_MASK(*ctl,
                                         NV_PGRAPH_TEXCTL0_0_MAX_LOD_CLAMP,
                                         last);
                                unsigned taps = profiles[profile].taps;
                                SET_MASK(*ctl,
                                         NV_PGRAPH_TEXCTL0_0_MAX_ANISOTROPY,
                                         taps == 8 ? 3 :
                                         taps == 4 ? 2 :
                                         taps == 2 ? 1 :
                                                     0);
                                pg->regs_[NV_PGRAPH_TEXFILTER0] =
                                    min << 16 | mag << 24 |
                                    ((unsigned)profiles[profile].bias & 8191) |
                                    (signedHILO ? 0xf0000000u : 0);
                                pg->regs_[NV_PGRAPH_TEXADDRESS0] =
                                    address | address << 8 | 3 << 16;
                                pg->regs_[NV_PGRAPH_BORDERCOLOR0] = 0xff128989;
                                cpu_write(8192, 512);
                                memset(state->vram_ptr + 8192, 0xd3, 512);
                                unsigned offset = 0;
                                for (unsigned level = 0;
                                     level < (rect ? 1u : 4u); level++) {
                                    unsigned width = 8 >> level;
                                    for (unsigned y = 0; y < width; y++)
                                        for (unsigned x = 0; x < width; x++) {
                                            unsigned pos =
                                                rect ?
                                                    y * 48 + x * 4 :
                                                    offset + 4 * signed_morton(
                                                                     x, y, 0,
                                                                     width, 1);
                                            stl_le_p(state->vram_ptr + 8192 +
                                                         pos,
                                                     hilo16_filter_word(x, y,
                                                                        level));
                                        }
                                    offset += width * width * 4;
                                }
                                NV2AMetalPGRAPHTextureSnapshot *original =
                                    prepare();
                                finish();
                                NSData *wire = [original
                                    snapshotWithCommands:surfaces.commands
                                                   error:&error];
                                require(wire != nil, error);
                                NV2AMetalPGRAPHTextureSnapshot *restored =
                                    [[NV2AMetalPGRAPHTextureSnapshot alloc]
                                        initWithSnapshot:wire
                                                commands:surfaces.commands
                                                   error:&error];
                                require(restored != nil, error);
                                if (signedHILO) {
                                    NSData *again = [restored
                                        snapshotWithCommands:surfaces.commands
                                                       error:&error];
                                    require(again != nil, error);
                                    assert([again isEqualToData:wire]);
                                    if (min == 1 && mag == 1 && address == 1 &&
                                        profile == 0) {
                                        id<MTLTexture> image =
                                            [original textureAtIndex:0]
                                                .binding.texture;
                                        for (unsigned level = first;
                                             level <= last; level++) {
                                            id<MTLBuffer> raw =
                                                read_subresource(
                                                    image, level - first, 0);
                                            finish();
                                            unsigned w = 8 >> level;
                                            for (unsigned y = 0; y < w; y++)
                                                for (unsigned x = 0; x < w;
                                                     x++) {
                                                    uint32_t word =
                                                        hilo16_filter_word(
                                                            x, y, level);
                                                    int hi = word >> 16,
                                                        lo = word & 65535;
                                                    const float expected[] = {
                                                        (hi >= 32768 ?
                                                             hi - 65536 :
                                                             hi) /
                                                            32768.f,
                                                        (lo >= 32768 ?
                                                             lo - 65536 :
                                                             lo) /
                                                            32768.f,
                                                        (lo >= 32768 ?
                                                             lo - 65536 :
                                                             lo) /
                                                            32768.f,
                                                        1
                                                    };
                                                    const float *actual =
                                                        (const float
                                                             *)((const uint8_t
                                                                     *)raw
                                                                    .contents +
                                                                y * 256 +
                                                                x * 16);
                                                    assert(!memcmp(
                                                        actual, expected,
                                                        sizeof(expected)));
                                                    rawTexels++;
                                                }
                                        }
                                    }
                                }
                                cpu_write(8192, 512);
                                memset(state->vram_ptr + 8192, 0x5b, 512);
                                captures++;
                                for (NV2AMetalPGRAPHTextureSnapshot *snapshot in
                                     @[ original, restored ])
                                    for (unsigned dependent = 0; dependent < 2;
                                         dependent++) {
                                        NV2AMetalPixelUniforms u = { 0 };
                                        NV2AMetalPixelTexture bindings[4] = {};
                                        require([snapshot
                                                    applyToUniforms:&u
                                                           textures:bindings
                                                              error:&error],
                                                error);
                                        assert(
                                            u.hilo16_mask == 1 &&
                                            u.textures[0].signed_channels ==
                                                (signedHILO ? 15u : 0u) &&
                                            u.textures[0].sampling.enabled &&
                                            u.textures[0].sampling.anisotropy ==
                                                taps);
                                        unsigned viewWidth = 8 >> first;
                                        assert(
                                            bindings[0].texture.width ==
                                                viewWidth &&
                                            bindings[0]
                                                    .texture.mipmapLevelCount ==
                                                last - first + 1);
                                        u.surface_scale[0] =
                                            u.surface_scale[1] = 1;
                                        u.smooth_shading = 1;
                                        u.clip_range[1] = u.clip_range[3] =
                                            65535;
                                        u.clip_regions[0][2] =
                                            u.clip_regions[0][3] = 8;
                                        u.combiner.shader_stage_program =
                                            PS_TEXTUREMODES_PROJECT2D;
                                        u.combiner.final_inputs[0] =
                                            PS_REGISTER_T0;
                                        u.combiner.final_inputs[1] =
                                            (PS_REGISTER_T0 | PS_CHANNEL_ALPHA)
                                            << 8;
                                        if (dependent) {
                                            u.combiner.shader_stage_program |=
                                                PS_TEXTUREMODES_DOTPRODUCT
                                                    << 5 |
                                                PS_TEXTUREMODES_DOT_ST << 10;
                                            unsigned mapping =
                                                (profile + address + min) % 8;
                                            u.other_stage_input =
                                                mapping | mapping << 4;
                                            u.textures[1].dimension =
                                                u.textures[2].dimension = 2;
                                            u.textures[2].scale = 1;
                                            u.textures[2].sampling.enabled = 1;
                                            u.textures[2].sampling.min_linear =
                                                u.textures[2]
                                                    .sampling.mag_linear = 1;
                                            for (unsigned j = 0; j < 3; j++)
                                                u.textures[2]
                                                    .sampling.address[j] = 3;
                                            u.textures[2].sampling.anisotropy =
                                                1;
                                            bindings[2].texture = lookup;
                                            bindings[2].sampler = sampler;
                                            u.combiner.final_inputs[0] =
                                                PS_REGISTER_T2;
                                            u.combiner.final_inputs[1] =
                                                (PS_REGISTER_T2 |
                                                 PS_CHANNEL_ALPHA)
                                                << 8;
                                        }
                                        NV2AMetalVertex vertices[6] = {};
                                        const float xy[][2] = {
                                            { -1, 1 }, { 1, 1 },  { -1, -1 },
                                            { 1, 1 },  { 1, -1 }, { -1, -1 }
                                        };
                                        double dx = profiles[profile].major /
                                                    viewWidth,
                                               dy = profiles[profile].minor /
                                                    viewWidth;
                                        for (unsigned j = 0; j < 6; j++) {
                                            vertices[j].clip[0] = xy[j][0];
                                            vertices[j].clip[1] = xy[j][1];
                                            vertices[j].clip[2] = .5f;
                                            vertices[j].clip[3] = 1;
                                            const float plane[3][4] = {
                                                { 0, 0, .5f, 1 },
                                                { 8, 0, .5f, 1 },
                                                { 0, 8, .5f, 1 }
                                            };
                                            memcpy(vertices[j].plane, plane,
                                                   sizeof(plane));
                                            double px = (xy[j][0] + 1) * 4,
                                                   py = (1 - xy[j][1]) * 4;
                                            vertices[j].texcoord[0][0] =
                                                (profiles[profile].s +
                                                 (px - 4) * dx) *
                                                (rect ? viewWidth : 1);
                                            vertices[j].texcoord[0][1] =
                                                (profiles[profile].t +
                                                 (py - 4) * dy) *
                                                (rect ? viewWidth : 1);
                                            vertices[j].texcoord[0][3] = 1;
                                            const float dotS[] = { .5f, .25f,
                                                                   .125f, 1 },
                                                        dotT[] = { .25f, .5f,
                                                                   .125f, 1 };
                                            memcpy(vertices[j].texcoord[1],
                                                   dotS, sizeof(dotS));
                                            memcpy(vertices[j].texcoord[2],
                                                   dotT, sizeof(dotT));
                                        }
                                        id<MTLBuffer> input = [surfaces.commands
                                                                   .device
                                            newBufferWithBytes:vertices
                                                        length:sizeof(vertices)
                                                       options:
                                                           MTLResourceStorageModeShared];
                                        assert(input);
                                        MTL4RenderPassDescriptor *pass =
                                            [MTL4RenderPassDescriptor new];
                                        pass.colorAttachments[0].texture =
                                            target;
                                        pass.colorAttachments[0].loadAction =
                                            MTLLoadActionClear;
                                        pass.colorAttachments[0].storeAction =
                                            MTLStoreActionStore;
                                        require(
                                            [surfaces
                                                prepareGPUReadAtAddress:0
                                                                 length:0
                                                                  error:&error],
                                            error);
                                        require(
                                            [shader
                                                encodeVertices:input
                                                         count:6
                                                     primitive:
                                                         MTLPrimitiveTypeTriangle
                                                      uniforms:&u
                                                      textures:bindings
                                                          pass:pass
                                                  depthStencil:nil
                                                      commands:surfaces.commands
                                                         error:&error],
                                            error);
                                        id<MTLBuffer> out =
                                            read_subresource(target, 0, 0);
                                        finish();
                                        for (unsigned py = 0; py < 8; py++)
                                            for (unsigned px = 0; px < 8;
                                                 px++) {
                                                double s = profiles[profile].s +
                                                           (px + .5 - 4) * dx,
                                                       t = profiles[profile].t +
                                                           (py + .5 - 4) * dy;
                                                double
                                                    hi =
                                                        hilo16_filter_reference(
                                                            s, t, dx, dy,
                                                            profiles[profile]
                                                                .lod,
                                                            taps, first, last,
                                                            address, min, mag,
                                                            0, signedHILO),
                                                    lo =
                                                        hilo16_filter_reference(
                                                            s, t, dx, dy,
                                                            profiles[profile]
                                                                .lod,
                                                            taps, first, last,
                                                            address, min, mag,
                                                            1, signedHILO);
                                                double normalZ =
                                                    signedHILO ?
                                                        sqrt(MAX(0.0,
                                                                 1 - hi * hi -
                                                                     lo * lo)) :
                                                        1;
                                                double lookupS = .5 * hi +
                                                                 .25 * lo +
                                                                 .125 * normalZ,
                                                       lookupT = .25 * hi +
                                                                 .5 * lo +
                                                                 .125 * normalZ;
                                                if (signedHILO) {
                                                    lookupS = MAX(
                                                        .0625,
                                                        MIN(.9375, lookupS));
                                                    lookupT = MAX(
                                                        .0625,
                                                        MIN(.9375, lookupT));
                                                }
                                                const double expected[] = {
                                                    dependent ?
                                                        lookupS :
                                                    signedHILO ?
                                                        MAX(0.0,
                                                            MIN(1.0,
                                                                hi * 65536 /
                                                                    65535)) :
                                                        hi,
                                                    dependent ?
                                                        lookupT :
                                                    signedHILO ?
                                                        MAX(0.0,
                                                            MIN(1.0,
                                                                lo * 65536 /
                                                                    65535)) :
                                                        lo,
                                                    dependent ?
                                                        .2 :
                                                    signedHILO ?
                                                        MAX(0.0,
                                                            MIN(1.0,
                                                                lo * 65536 /
                                                                    65535)) :
                                                        lo,
                                                    dependent ? .75 : 1
                                                };
                                                const float *actual =
                                                    (const float
                                                         *)((const uint8_t *)
                                                                out.contents +
                                                            py * 256 + px * 16);
                                                for (unsigned k = 0; k < 4;
                                                     k++) {
                                                    if (!isfinite(actual[k]) ||
                                                        fabs(actual[k] -
                                                             expected[k]) >
                                                            (signedHILO ?
                                                                 .000002 :
                                                                 .00003)) {
                                                        fprintf(
                                                            stderr,
                                                            "HILO filter "
                                                            "rect%u "
                                                            "range%u min%u "
                                                            "mag%u "
                                                            "addr%u profile%u "
                                                            "dependent%u "
                                                            "pixel%u,%u "
                                                            "channel%u: "
                                                            "%.9g expected "
                                                            "%.9g\n",
                                                            rect, range, min,
                                                            mag, address,
                                                            profile, dependent,
                                                            px, py, k,
                                                            actual[k],
                                                            expected[k]);
                                                        abort();
                                                    }
                                                    channels++;
                                                }
                                            }
                                        draws++;
                                        eightTapDraws += taps == 8;
                                    }
                            }
                        }
    assert(captures == 3000 && draws == 12000 && channels == 3072000 &&
           eightTapDraws == 1200);
    if (signedHILO) {
        assert(rawTexels == 258);
        PGRAPHState *pg = &state->pgraph;
        unsigned filter = pg->regs_[NV_PGRAPH_TEXFILTER0] & 0x0fffffff;
        for (unsigned mask = 1; mask < 15; mask++) {
            pg->regs_[NV_PGRAPH_TEXFILTER0] =
                filter | (mask & 1 ? NV_PGRAPH_TEXFILTER0_RSIGNED : 0) |
                (mask & 2 ? NV_PGRAPH_TEXFILTER0_GSIGNED : 0) |
                (mask & 4 ? NV_PGRAPH_TEXFILTER0_BSIGNED : 0) |
                (mask & 8 ? NV_PGRAPH_TEXFILTER0_ASIGNED : 0);
            pg->texture_dirty[0] = true;
            assert(![adapter prepareWithError:&error] && pg->texture_dirty[0]);
        }
        printf("Metal4 signed HILO16: 3000 exact Stage3 resaves/258 bit-exact "
               "raw texels/14 mixed-mask rejections PASS\n");
    }
    printf("Metal4 %sHILO16 input filters: %u captures/restores/%u draws/"
           "%u full-frame channels/%u actual eight-tap draws PASS\n",
           signedHILO ? "signed " : "", captures, draws, channels,
           eightTapDraws);
}

static uint32_t hilo16_volume_word(unsigned x, unsigned y, unsigned z,
                                   unsigned face, unsigned level)
{
    return hilo16_filter_word(x + 5 * z + 7 * face, y, level);
}
static double hilo16_word_component(uint32_t word, unsigned channel,
                                    BOOL signedHILO)
{
    if (channel == 2)
        return 1;
    int raw = channel ? word & 65535 : word >> 16;
    return signedHILO ? (raw >= 32768 ? raw - 65536 : raw) / 32768.0 :
                        raw / 65535.0;
}
static double hilo16_rect_level(double s, double t, double r,
                                const unsigned physical[3], unsigned level,
                                unsigned face, bool volume, unsigned address,
                                bool linear, unsigned channel,
                                bool physicalBorder, BOOL signedHILO)
{
    double c[] = { s, t, volume ? r : .5 };
    unsigned dimensions[] = { MAX(1u, physical[0] >> level),
                              MAX(1u, physical[1] >> level),
                              MAX(1u, physical[2] >> level) };
    int base[3];
    double fraction[3];
    for (unsigned axis = 0; axis < 3; axis++) {
        if (address == 1)
            c[axis] -= floor(c[axis]);
        if (address == 2) {
            c[axis] = fmod(c[axis], 2);
            if (c[axis] < 0)
                c[axis] += 2;
            c[axis] = c[axis] <= 1 ? c[axis] : 2 - c[axis];
        }
        double position = c[axis] * dimensions[axis] - (linear ? .5 : 0);
        base[axis] = floor(position);
        fraction[axis] = position - base[axis];
    }
    unsigned corners = linear ? (volume ? 8 : 4) : 1;
    double result = 0;
    for (unsigned corner = 0; corner < corners; corner++) {
        double weight = 1;
        int coordinate[3];
        bool border = false;
        for (unsigned axis = 0; axis < 3; axis++) {
            unsigned high = (corner >> axis) & 1;
            coordinate[axis] = base[axis] + high;
            if (linear && (volume || axis < 2))
                weight *= high ? fraction[axis] : 1 - fraction[axis];
            if (address == 1)
                coordinate[axis] = (coordinate[axis] % (int)dimensions[axis] +
                                    dimensions[axis]) %
                                   dimensions[axis];
            else if (address == 4 &&
                     (coordinate[axis] < 0 ||
                      coordinate[axis] >= (int)dimensions[axis]))
                border = true;
            else
                coordinate[axis] =
                    MAX(0, MIN((int)dimensions[axis] - 1, coordinate[axis]));
        }
        uint32_t word = border ?
                            0 :
                            hilo16_volume_word(coordinate[0], coordinate[1],
                                               coordinate[2], face, level);
        int rawBorder = channel ? 0x89 : 0x12;
        double borderValue =
            signedHILO ?
                (channel == 2 ?
                     1 :
                     (rawBorder >= 128 ? rawBorder - 256 : rawBorder) / 128.0) :
                (channel == 2 ? 1 : rawBorder / 255.0);
        double value = border ?
                           (physicalBorder ? 0 : borderValue) :
                           hilo16_word_component(word, channel, signedHILO);
        result += weight * value;
    }
    return result;
}
static double hilo16_rect_reference(double s, double t, double r, double dx,
                                    double lod, unsigned taps,
                                    const unsigned physical[3], unsigned first,
                                    unsigned last, unsigned face, bool volume,
                                    unsigned address, unsigned min,
                                    unsigned mag, unsigned channel,
                                    bool physicalBorder, BOOL signedHILO)
{
    bool linear = lod <= 0 ? mag == 2 : min % 2 == 0;
    double l = min < 3 ? 0 : MAX(0, MIN((double)(last - first), lod));
    unsigned low = 0, high = 0;
    double blend = 0;
    if (min >= 5) {
        low = floor(l);
        high = MIN(low + 1, last - first);
        blend = l - low;
    } else if (min >= 3) {
        for (unsigned i = 1; i <= last - first; i++)
            if (fabs(l - i) < fabs(l - low))
                low = i;
        high = low;
    }
    double result = 0;
    for (unsigned tap = 0; tap < taps; tap++) {
        double u = s + (((double)tap + 1) / (taps + 1) - .5) * dx;
        double a = hilo16_rect_level(u, t, r, physical, first + low, face,
                                     volume, address, linear, channel,
                                     physicalBorder, signedHILO),
               b = hilo16_rect_level(u, t, r, physical, first + high, face,
                                     volume, address, linear, channel,
                                     physicalBorder, signedHILO);
        result += a * (1 - blend) + b * blend;
    }
    return result / taps;
}
static double hilo16_volume_level(double s, double t, double r, unsigned size,
                                  unsigned level, unsigned face, bool volume,
                                  unsigned address, bool linear,
                                  unsigned channel, bool physicalBorder,
                                  BOOL signedHILO)
{
    const unsigned physical[] = { size, size, volume ? size : 1 };
    return hilo16_rect_level(s, t, r, physical, level, face, volume, address,
                             linear, channel, physicalBorder, signedHILO);
}
static double hilo16_volume_reference(double s, double t, double r, double dx,
                                      double lod, unsigned taps, unsigned size,
                                      unsigned first, unsigned last,
                                      unsigned face, bool volume,
                                      unsigned address, unsigned min,
                                      unsigned mag, unsigned channel,
                                      bool physicalBorder, BOOL signedHILO)
{
    const unsigned physical[] = { size, size, volume ? size : 1 };
    return hilo16_rect_reference(s, t, r, dx, lod, taps, physical, first, last,
                                 face, volume, address, min, mag, channel,
                                 physicalBorder, signedHILO);
}
static id<MTLBuffer> hilo16_volume_draw(NV2AMetalPixelShader *shader,
                                        id<MTLTexture> target,
                                        NV2AMetalPixelUniforms *u,
                                        NV2AMetalPixelTexture bindings[4],
                                        NV2AMetalVertex vertices[6])
{
    NSError *error = nil;
    id<MTLBuffer> input = [surfaces.commands.device
        newBufferWithBytes:vertices
                    length:6 * sizeof(*vertices)
                   options:MTLResourceStorageModeShared];
    assert(input);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    require([surfaces prepareGPUReadAtAddress:0 length:0 error:&error], error);
    require([shader encodeVertices:input
                             count:6
                         primitive:MTLPrimitiveTypeTriangle
                          uniforms:u
                          textures:bindings
                              pass:pass
                      depthStencil:nil
                          commands:surfaces.commands
                             error:&error],
            error);
    id<MTLBuffer> out = read_subresource(target, 0, 0);
    finish();
    return out;
}
static void hilo16_cube_volume_filter_tests(BOOL signedHILO)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:surfaces.commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:4
                                    height:4
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target =
        [surfaces.commands.device newTextureWithDescriptor:td];
    td.width = td.height = 8;
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> lookup =
        [surfaces.commands.device newTextureWithDescriptor:td];
    assert(target && lookup);
    float gradient[8][8][4];
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            const float pixel[] = { (x + .5f) / 8, (y + .5f) / 8, .2f, .75f };
            memcpy(gradient[y][x], pixel, sizeof(pixel));
        }
    [lookup replaceRegion:MTLRegionMake2D(0, 0, 8, 8)
              mipmapLevel:0
                withBytes:gradient
              bytesPerRow:sizeof(gradient[0])];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> sampler =
        [surfaces.commands.device newSamplerStateWithDescriptor:sd];
    assert(sampler);
    const unsigned cubeRanges[][2] = { { 0, 4 }, { 1, 3 }, { 2, 2 } };
    unsigned captures = 0, draws = 0, channels = 0, eightTapDraws = 0,
             rawTexels = 0;
    unsigned pointSlices[4] = { 0 };
    for (unsigned volume = 0; volume < 2; volume++)
        for (unsigned range = 0; range < (volume ? 4u : 3u); range++)
            for (unsigned face = 0; face < (volume ? 1u : 6u); face++)
                for (unsigned min = 1; min <= 6; min++)
                    for (unsigned mag = 1; mag <= 2; mag++)
                        for (unsigned a = 0; a < (volume ? 5u : 1u); a++)
                            for (unsigned profile = 0; profile < 6; profile++) {
                                @autoreleasepool {
                                    unsigned address = volume ? a + 1 : 3;
                                    unsigned size = volume ? 8 : 16;
                                    unsigned first =
                                        volume ? range : cubeRanges[range][0];
                                    unsigned last =
                                        volume ? 3 : cubeRanges[range][1];
                                    unsigned requested = profile == 4 ? 4 :
                                                         profile == 5 ? 8 :
                                                                        1;
                                    unsigned taps = first == 0 ? requested : 1;
                                    double dx = profile < 2  ? 0 :
                                                profile >= 4 ? 2.0 / size :
                                                               1.0 / size;
                                    double dy = profile >= 4 ? dx / 8 : dx;
                                    double centerS = profile == 1 ? .03125 : .5,
                                           centerT = profile == 1 ? .96875 : .5,
                                           centerR =
                                               profile == 1 ?
                                                   .96875 :
                                               volume ?
                                                   ((min + 2 * a + profile) %
                                                        7 +
                                                    .75) /
                                                       8 :
                                                   .375;
                                    if (volume && min == 1 && mag == 1) {
                                        unsigned slice =
                                            floor(centerR * (size >> first));
                                        pointSlices[first] |= 1u << slice;
                                    }
                                    double lod = profile < 2  ? -100 :
                                                 profile == 2 ? .5 :
                                                                .75;
                                    int bias =
                                        profile < 2  ? 0 :
                                        profile == 2 ? first * 256 + 128 :
                                        profile == 3 ? first * 256 + 192 :
                                        first        ? first * 256 - 64 :
                                        profile == 4 ? 448 :
                                                       704;
                                    PGRAPHState *pg = &state->pgraph;
                                    for (unsigned i = 0; i < 4; i++)
                                        pg->regs_[NV_PGRAPH_TEXCTL0_0 + i * 4] =
                                            0;
                                    pg->regs_[NV_PGRAPH_SHADERPROG] = 0;
                                    registers(
                                        0,
                                        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16,
                                        size, 0, 4096, false);
                                    uint32_t *fmt =
                                        &pg->regs_[NV_PGRAPH_TEXFMT0];
                                    SET_MASK(*fmt,
                                             NV_PGRAPH_TEXFMT0_BASE_SIZE_U,
                                             volume ? 3 : 4);
                                    SET_MASK(*fmt,
                                             NV_PGRAPH_TEXFMT0_BASE_SIZE_V,
                                             volume ? 3 : 4);
                                    SET_MASK(*fmt,
                                             NV_PGRAPH_TEXFMT0_BASE_SIZE_P,
                                             volume ? 3 : 0);
                                    SET_MASK(*fmt,
                                             NV_PGRAPH_TEXFMT0_DIMENSIONALITY,
                                             volume ? 3 : 2);
                                    SET_MASK(*fmt,
                                             NV_PGRAPH_TEXFMT0_MIPMAP_LEVELS,
                                             5);
                                    SET_MASK(*fmt,
                                             NV_PGRAPH_TEXFMT0_CUBEMAPENABLE,
                                             !volume);
                                    uint32_t *ctl =
                                        &pg->regs_[NV_PGRAPH_TEXCTL0_0];
                                    SET_MASK(*ctl,
                                             NV_PGRAPH_TEXCTL0_0_MIN_LOD_CLAMP,
                                             first);
                                    // Request all 3D mips, including 2³ and 1³.
                                    SET_MASK(*ctl,
                                             NV_PGRAPH_TEXCTL0_0_MAX_LOD_CLAMP,
                                             volume ? 4 : last);
                                    SET_MASK(*ctl,
                                             NV_PGRAPH_TEXCTL0_0_MAX_ANISOTROPY,
                                             requested == 8 ? 3 :
                                             requested == 4 ? 2 :
                                                              0);
                                    pg->regs_[NV_PGRAPH_TEXFILTER0] =
                                        min << 16 | mag << 24 | (bias & 8191) |
                                        (signedHILO ? 0xf0000000u : 0);
                                    pg->regs_[NV_PGRAPH_TEXADDRESS0] =
                                        address | address << 8 | address << 16;
                                    pg->regs_[NV_PGRAPH_BORDERCOLOR0] =
                                        0xff128989;
                                    pg->regs_[NV_PGRAPH_SHADERPROG] =
                                        volume ? PS_TEXTUREMODES_PROJECT3D :
                                                 PS_TEXTUREMODES_CUBEMAP;
                                    unsigned length = volume ? 2340 : 8448;
                                    cpu_write(8192, length);
                                    memset(state->vram_ptr + 8192, 0xd3,
                                           length);
                                    for (unsigned sourceFace = 0;
                                         sourceFace < (volume ? 1u : 6u);
                                         sourceFace++) {
                                        unsigned offset = sourceFace * 1408;
                                        for (unsigned level = 0;
                                             level < (volume ? 4u : 5u);
                                             level++) {
                                            unsigned w = size >> level,
                                                     d = volume ? w : 1;
                                            for (unsigned z = 0; z < d; z++)
                                                for (unsigned y = 0; y < w; y++)
                                                    for (unsigned x = 0; x < w;
                                                         x++)
                                                        stl_le_p(
                                                            state->vram_ptr +
                                                                8192 + offset +
                                                                4 * signed_morton(
                                                                        x, y, z,
                                                                        w, d),
                                                            hilo16_volume_word(
                                                                x, y, z,
                                                                sourceFace,
                                                                level));
                                            offset += 4 * w * w * d;
                                        }
                                    }
                                    NV2AMetalPGRAPHTextureSnapshot *original =
                                        prepare();
                                    finish();
                                    NSData *wire = [original
                                        snapshotWithCommands:surfaces.commands
                                                       error:&error];
                                    require(wire != nil, error);
                                    NV2AMetalPGRAPHTextureSnapshot *restored =
                                        [[NV2AMetalPGRAPHTextureSnapshot alloc]
                                            initWithSnapshot:wire
                                                    commands:surfaces.commands
                                                       error:&error];
                                    require(restored != nil, error);
                                    if (signedHILO) {
                                        NSData *again = [restored
                                            snapshotWithCommands:surfaces
                                                                     .commands
                                                           error:&error];
                                        require(again != nil, error);
                                        assert([again isEqualToData:wire]);
                                    }

                                    cpu_write(8192, length);
                                    memset(state->vram_ptr + 8192, 0x5b,
                                           length);
                                    captures++;
                                    for (NV2AMetalPGRAPHTextureSnapshot
                                             *snapshot in
                                         @[ original, restored ])
                                        for (unsigned dependent = 0;
                                             dependent < 2; dependent++) {
                                            NV2AMetalPixelUniforms u = { 0 };
                                            NV2AMetalPixelTexture
                                                bindings[4] = {};
                                            require([snapshot
                                                        applyToUniforms:&u
                                                               textures:bindings
                                                                  error:&error],
                                                    error);
                                            assert(
                                                u.hilo16_mask == 1 &&
                                                u.textures[0].signed_channels ==
                                                    (signedHILO ? 15u : 0u) &&
                                                bindings[0].texture.width ==
                                                    size >> first &&
                                                bindings[0]
                                                        .texture
                                                        .mipmapLevelCount ==
                                                    last - first + 1);
                                            assert(bindings[0]
                                                       .texture.textureType ==
                                                   (volume ?
                                                        MTLTextureType3D :
                                                        MTLTextureTypeCube));
                                            assert(!volume ||
                                                   bindings[0].texture.depth ==
                                                       size >> first);
                                            if (signedHILO && !dependent &&
                                                min == 1 && mag == 1 &&
                                                a == 0 && profile == 0) {
                                                id<MTLTexture> texture =
                                                    bindings[0].texture;
                                                for (unsigned level = first;
                                                     level <= last; level++) {
                                                    unsigned width =
                                                                 size >> level,
                                                             depth = volume ?
                                                                         width :
                                                                         1;
                                                    id<MTLBuffer> raw =
                                                        read_subresource(
                                                            texture,
                                                            level - first,
                                                            volume ? 0 : face);
                                                    finish();
                                                    NSUInteger row =
                                                        (width * 16 + 255) &
                                                        ~255u;
                                                    for (unsigned z = 0;
                                                         z < depth; z++)
                                                        for (unsigned y = 0;
                                                             y < width; y++)
                                                            for (unsigned x = 0;
                                                                 x < width;
                                                                 x++) {
                                                                uint32_t word =
                                                                    hilo16_volume_word(
                                                                        x, y, z,
                                                                        volume ?
                                                                            0 :
                                                                            face,
                                                                        level);
                                                                const float
                                                                    expected[] = {
                                                                        hilo16_word_component(
                                                                            word,
                                                                            0,
                                                                            YES),
                                                                        hilo16_word_component(
                                                                            word,
                                                                            1,
                                                                            YES),
                                                                        hilo16_word_component(
                                                                            word,
                                                                            1,
                                                                            YES),
                                                                        1
                                                                    };
                                                                const float *actual =
                                                                    (const float
                                                                         *)((const uint8_t
                                                                                 *)raw
                                                                                .contents +
                                                                            (z * width +
                                                                             y) *
                                                                                row +
                                                                            x * 16);
                                                                assert(!memcmp(
                                                                    actual,
                                                                    expected,
                                                                    sizeof(
                                                                        expected)));
                                                                rawTexels++;
                                                            }
                                                }
                                            }
                                            u.surface_scale[0] =
                                                u.surface_scale[1] = 1;
                                            u.smooth_shading = 1;
                                            u.clip_range[1] = u.clip_range[3] =
                                                65535;
                                            u.clip_regions[0][2] =
                                                u.clip_regions[0][3] = 4;
                                            u.combiner.shader_stage_program =
                                                volume ?
                                                    PS_TEXTUREMODES_PROJECT3D :
                                                    PS_TEXTUREMODES_CUBEMAP;
                                            u.combiner.final_inputs[0] =
                                                PS_REGISTER_T0;
                                            u.combiner.final_inputs[1] =
                                                (PS_REGISTER_T0 |
                                                 PS_CHANNEL_ALPHA)
                                                << 8;
                                            if (dependent) {
                                                u.combiner
                                                    .shader_stage_program |=
                                                    PS_TEXTUREMODES_DOTPRODUCT
                                                        << 5 |
                                                    PS_TEXTUREMODES_DOT_ST
                                                        << 10;
                                                unsigned mapping =
                                                    (face + min + profile) % 8;
                                                u.other_stage_input =
                                                    mapping | mapping << 4;
                                                u.textures[1].dimension =
                                                    u.textures[2].dimension = 2;
                                                u.textures[2].scale = 1;
                                                u.textures[2].sampling.enabled =
                                                    1;
                                                u.textures[2]
                                                    .sampling.min_linear =
                                                    u.textures[2]
                                                        .sampling.mag_linear =
                                                        1;
                                                u.textures[2]
                                                    .sampling.anisotropy = 1;
                                                for (unsigned axis = 0;
                                                     axis < 3; axis++)
                                                    u.textures[2]
                                                        .sampling
                                                        .address[axis] = 3;
                                                bindings[2].texture = lookup;
                                                bindings[2].sampler = sampler;
                                                u.combiner.final_inputs[0] =
                                                    PS_REGISTER_T2;
                                                u.combiner.final_inputs[1] =
                                                    (PS_REGISTER_T2 |
                                                     PS_CHANNEL_ALPHA)
                                                    << 8;
                                            }
                                            NV2AMetalVertex vertices[6] = {};
                                            const float xy[][2] = {
                                                { -1, 1 },  { 1, 1 },
                                                { -1, -1 }, { 1, 1 },
                                                { 1, -1 },  { -1, -1 }
                                            };
                                            for (unsigned j = 0; j < 6; j++) {
                                                vertices[j].clip[0] = xy[j][0];
                                                vertices[j].clip[1] = xy[j][1];
                                                vertices[j].clip[2] = .5f;
                                                vertices[j].clip[3] = 1;
                                                const float plane[3][4] = {
                                                    { 0, 0, .5f, 1 },
                                                    { 4, 0, .5f, 1 },
                                                    { 0, 4, .5f, 1 }
                                                };
                                                memcpy(vertices[j].plane, plane,
                                                       sizeof(plane));
                                                double s = centerS +
                                                           xy[j][0] * 2 * dx,
                                                       t = centerT -
                                                           xy[j][1] * 2 * dy;
                                                float *c =
                                                    vertices[j].texcoord[0];
                                                if (volume) {
                                                    c[0] = s;
                                                    c[1] = t;
                                                    c[2] = centerR;
                                                } else {
                                                    double us = 2 * s - 1,
                                                           vt = 2 * t - 1;
                                                    const float
                                                        directions[][3] = {
                                                            { 1, -vt, -us },
                                                            { -1, -vt, us },
                                                            { us, 1, vt },
                                                            { us, -1, -vt },
                                                            { us, -vt, 1 },
                                                            { -us, -vt, -1 }
                                                        };
                                                    memcpy(c, directions[face],
                                                           3 * sizeof(float));
                                                }
                                                c[3] = 1;
                                                const float dotS[] = { .5f,
                                                                       .25f,
                                                                       .125f,
                                                                       1 },
                                                            dotT[] = { .25f,
                                                                       .5f,
                                                                       .125f,
                                                                       1 };
                                                memcpy(vertices[j].texcoord[1],
                                                       dotS, sizeof(dotS));
                                                memcpy(vertices[j].texcoord[2],
                                                       dotT, sizeof(dotT));
                                            }
                                            id<MTLBuffer> out =
                                                hilo16_volume_draw(
                                                    shader, target, &u,
                                                    bindings, vertices);
                                            for (unsigned py = 0; py < 4; py++)
                                                for (unsigned px = 0; px < 4;
                                                     px++) {
                                                    double s = centerS +
                                                               (px + .5 - 2) *
                                                                   dx,
                                                           t = centerT +
                                                               (py + .5 - 2) *
                                                                   dy;
                                                    double
                                                        hi =
                                                            hilo16_volume_reference(
                                                                s, t, centerR,
                                                                dx, lod, taps,
                                                                size, first,
                                                                last, face,
                                                                volume, address,
                                                                min, mag, 0,
                                                                false,
                                                                signedHILO),
                                                        lo =
                                                            hilo16_volume_reference(
                                                                s, t, centerR,
                                                                dx, lod, taps,
                                                                size, first,
                                                                last, face,
                                                                volume, address,
                                                                min, mag, 1,
                                                                false,
                                                                signedHILO);
                                                    double normalZ =
                                                        signedHILO ?
                                                            sqrt(MAX(
                                                                0.0,
                                                                1 - hi * hi -
                                                                    lo * lo)) :
                                                            1;
                                                    double lookupS =
                                                               .5 * hi +
                                                               .25 * lo +
                                                               .125 * normalZ,
                                                           lookupT =
                                                               .25 * hi +
                                                               .5 * lo +
                                                               .125 * normalZ;
                                                    const double expected[] = {
                                                        dependent ?
                                                            (signedHILO ?
                                                                 MAX(.0625,
                                                                     MIN(.9375,
                                                                         lookupS)) :
                                                                 lookupS) :
                                                            (signedHILO ?
                                                                 MAX(0.0,
                                                                     hi *
                                                                         65536 /
                                                                         65535) :
                                                                 hi),
                                                        dependent ?
                                                            (signedHILO ?
                                                                 MAX(.0625,
                                                                     MIN(.9375,
                                                                         lookupT)) :
                                                                 lookupT) :
                                                            (signedHILO ?
                                                                 MAX(0.0,
                                                                     lo *
                                                                         65536 /
                                                                         65535) :
                                                                 lo),
                                                        dependent ?
                                                            .2 :
                                                            (signedHILO ?
                                                                 MAX(0.0,
                                                                     lo *
                                                                         65536 /
                                                                         65535) :
                                                                 lo),
                                                        dependent ? .75 : 1
                                                    };
                                                    const float *actual =
                                                        (const float
                                                             *)((const uint8_t
                                                                     *)out
                                                                    .contents +
                                                                py * 256 +
                                                                px * 16);
                                                    for (unsigned k = 0; k < 4;
                                                         k++) {
                                                        if (!isfinite(
                                                                actual[k]) ||
                                                            fabs(actual[k] -
                                                                 expected[k]) >
                                                                (signedHILO ?
                                                                     .000002 :
                                                                     .00003)) {
                                                            fprintf(
                                                                stderr,
                                                                "HILO "
                                                                "subfilter "
                                                                "volume%u "
                                                                "range%u "
                                                                "face%u min%u "
                                                                "mag%u addr%u "
                                                                "profile%u "
                                                                "dep%u "
                                                                "pixel%u,%u "
                                                                "channel%u: "
                                                                "%.9g expected "
                                                                "%.9g\n",
                                                                volume, range,
                                                                face, min, mag,
                                                                address,
                                                                profile,
                                                                dependent, px,
                                                                py, k,
                                                                actual[k],
                                                                expected[k]);
                                                            abort();
                                                        }
                                                        channels++;
                                                    }
                                                }
                                            draws++;
                                            eightTapDraws += taps == 8;
                                        }
                                }
                            }
    assert(captures == 2736 && draws == 10944 && channels == 700416 &&
           eightTapDraws == 528 && pointSlices[0] == 255 &&
           pointSlices[1] == 15 && pointSlices[2] == 3 && pointSlices[3] == 1);
    if (signedHILO)
        assert(rawTexels == 6628);
    printf("Metal4 %sHILO16 Cube/3D filters: %u captures/restores/%u draws/%u "
           "full-frame channels/%u eight-tap draws PASS\n",
           signedHILO ? "signed " : "", captures, draws, channels,
           eightTapDraws);
    if (signedHILO)
        printf("Metal4 signed HILO16 Cube/3D: 2736 exact Stage3 resaves/6628 "
               "bit-exact raw texels PASS\n");
}

static unsigned volume_mip_morton(unsigned x, unsigned y, unsigned z,
                                  unsigned width, unsigned height,
                                  unsigned depth)
{
    const unsigned coordinate[] = { x, y, z },
                   size[] = { width, height, depth };
    unsigned result = 0, output = 1;
    for (unsigned bit = 1; bit < MAX(width, MAX(height, depth)); bit <<= 1)
        for (unsigned axis = 0; axis < 3; axis++)
            if (bit < size[axis]) {
                if (coordinate[axis] & bit)
                    result |= output;
                output <<= 1;
            }
    return result;
}
static double hilo16_gradient_reference(
    const double c[3], const double gradient[2][3], const unsigned physical[3],
    unsigned first, unsigned last, bool volume, unsigned address, unsigned min,
    unsigned mag, unsigned anisotropy, double bias, unsigned channel,
    bool physicalBorder, BOOL signedHILO, unsigned *tapCount)
{
    double lengthSquared[2] = {};
    for (unsigned screen = 0; screen < 2; screen++)
        for (unsigned axis = 0; axis < (volume ? 3u : 2u); axis++) {
            double texels =
                gradient[screen][axis] * MAX(1u, physical[axis] >> first);
            lengthSquared[screen] += texels * texels;
        }
    unsigned major = lengthSquared[0] > lengthSquared[1] ? 0 : 1;
    double longest = sqrt(lengthSquared[major]),
           shortest = sqrt(lengthSquared[1 - major]);
    unsigned taps =
        longest > 1 ?
            MIN(anisotropy,
                MAX(1u, (unsigned)ceil(longest / MAX(shortest, 1e-30)))) :
            1;
    *tapCount = taps;
    double lod = log2(MAX(longest / taps, 1e-30)) + bias;
    double result = 0;
    for (unsigned tap = 0; tap < taps; tap++) {
        double position[3], offset = (tap + 1.0) / (taps + 1.0) - .5;
        for (unsigned axis = 0; axis < 3; axis++)
            position[axis] = c[axis] + offset * gradient[major][axis];
        // The single-tap oracle independently handles mip selection and
        // texel interpolation; gradients are in the rebased view's space.
        result += hilo16_rect_reference(position[0], position[1], position[2],
                                        0, lod, 1, physical, first, last, 0,
                                        volume, address, min, mag, channel,
                                        physicalBorder, signedHILO);
    }
    return result / taps;
}

static void hilo16_projected_coordinate(const double origin[3],
                                        const double gradient[2][3], double q,
                                        const double dq[2], double x, double y,
                                        double result[3])
{
    double denominator = q + x * dq[0] + y * dq[1];
    assert(denominator > 0);
    for (unsigned axis = 0; axis < 3; axis++)
        result[axis] =
            q * (origin[axis] + x * gradient[0][axis] + y * gradient[1][axis]) /
            denominator;
}

// Mode 0 keeps the affine swizzled matrix; 1 adds linear rectangles, and 2
// exercises varying projective denominators in swizzled 2D/3D mip views.
static void hilo16_gradient_tests(unsigned mode, unsigned scale)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:surfaces.commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:4 * scale
                                    height:4 * scale
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target =
        [surfaces.commands.device newTextureWithDescriptor:td];
    td.width = td.height = 8;
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> lookup =
        [surfaces.commands.device newTextureWithDescriptor:td];
    assert(target && lookup);
    float pixels[8][8][4];
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            const float pixel[] = { (x + .5f) / 8, (y + .5f) / 8, .2f, .75f };
            memcpy(pixels[y][x], pixel, sizeof(pixel));
        }
    [lookup replaceRegion:MTLRegionMake2D(0, 0, 8, 8)
              mipmapLevel:0
                withBytes:pixels
              bytesPerRow:sizeof(pixels[0])];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> sampler =
        [surfaces.commands.device newSamplerStateWithDescriptor:sd];
    assert(sampler);
    const unsigned logs[][3] = {
        { 3, 2, 0 }, { 1, 3, 0 }, { 3, 2, 1 }, { 1, 2, 3 }
    };
    const unsigned rectangles[][3] = { { 8, 4, 1 }, { 6, 5, 1 }, { 5, 9, 1 } };
    const double qProfiles[][3] = {
        { .5, 0, 0 },         { 1, 0, 0 },           { 2, 0, 0 },
        { 1, .0625, .03125 }, { 1, -.03125, .0625 }, { 1, .125, -.0625 }
    };
    bool rectangle = mode == 1;
    const unsigned addresses[] = { 1, 3, 4 };
    // Major/minor vectors in view-base texels. Exchange screen axes below.
    const double directions[][2][3] = {
        { { 0, 4, 0 }, { .25, 0, 0 } },
        { { 0, -4, 0 }, { .25, 0, 0 } },
        { { 2.4, 3.2, 0 }, { -.2, .15, 0 } },
        { { -2.4, 3.2, 0 }, { .2, .15, 0 } },
        { { 0, 0, 4 }, { .15, .2, 0 } },
        { { 0, 2.4, -3.2 }, { .25, 0, 0 } },
    };
    unsigned captures = 0, draws = 0, channels = 0, dotDraws = 0;
    unsigned tapDraws[3] = {}, directionDraws[6] = {}, majorDraws[2] = {};
    unsigned pixelTaps[8] = {}, profileDraws[6] = {};
    unsigned rawTexels = 0, shortDMA = 0;
    DMAObject oldDMA = dma_a;
    for (unsigned signedHILO = 0; signedHILO < 2; signedHILO++)
        for (unsigned shape = 0;
             shape < (rectangle ? ARRAY_SIZE(rectangles) : ARRAY_SIZE(logs));
             shape++)
            for (unsigned border = 0; border < (rectangle ? 1u : 2u); border++)
                for (unsigned stageIndex = 0; stageIndex < 2; stageIndex++)
                    for (unsigned first = 0; first < (rectangle ? 1u : 2u);
                         first++)
                        for (unsigned af = 0; af < 3; af++)
                            for (unsigned filter = 0; filter < 2; filter++)
                                for (unsigned a = 0; a < ARRAY_SIZE(addresses);
                                     a++) {
                                    @autoreleasepool {
                                        bool volume = !rectangle && shape >= 2;
                                        unsigned stage = stageIndex * 3;
                                        unsigned core[3], physical[3];
                                        for (unsigned axis = 0; axis < 3;
                                             axis++) {
                                            core[axis] =
                                                rectangle ?
                                                    rectangles[shape][axis] :
                                                    1u << logs[shape][axis];
                                            physical[axis] =
                                                !volume && axis == 2 ?
                                                    1 :
                                                border ?
                                                    MAX(16u, 2 * core[axis]) :
                                                    core[axis];
                                        }
                                        unsigned last = rectangle ? 0 : 3,
                                                 min = rectangle ? filter + 1 :
                                                       filter    ? 6 :
                                                                   4,
                                                 requested = 2u << af,
                                                 address = addresses[a];
                                        PGRAPHState *pg = &state->pgraph;
                                        for (unsigned i = 0; i < 4; i++)
                                            pg->regs_[NV_PGRAPH_TEXCTL0_0 +
                                                      4 * i] = 0;
                                        pg->regs_[NV_PGRAPH_SHADERPROG] = 0;
                                        registers(
                                            stage,
                                            rectangle ?
                                                NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16 :
                                                NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16,
                                            core[0], rectangle ? 64 : 0, 4096,
                                            false);
                                        unsigned slot = stage * 4;
                                        pg->regs_[NV_PGRAPH_TEXIMAGERECT0 +
                                                  slot] =
                                            core[0] << 16 | core[1];
                                        uint32_t *fmt =
                                            &pg->regs_[NV_PGRAPH_TEXFMT0 +
                                                       slot];
                                        SET_MASK(
                                            *fmt,
                                            NV_PGRAPH_TEXFMT0_BORDER_SOURCE,
                                            !border);
                                        SET_MASK(*fmt,
                                                 NV_PGRAPH_TEXFMT0_BASE_SIZE_U,
                                                 logs[shape][0]);
                                        SET_MASK(*fmt,
                                                 NV_PGRAPH_TEXFMT0_BASE_SIZE_V,
                                                 logs[shape][1]);
                                        SET_MASK(*fmt,
                                                 NV_PGRAPH_TEXFMT0_BASE_SIZE_P,
                                                 logs[shape][2]);
                                        SET_MASK(
                                            *fmt,
                                            NV_PGRAPH_TEXFMT0_DIMENSIONALITY,
                                            volume ? 3 : 2);
                                        SET_MASK(
                                            *fmt,
                                            NV_PGRAPH_TEXFMT0_MIPMAP_LEVELS,
                                            last + 1);
                                        uint32_t *ctl =
                                            &pg->regs_[NV_PGRAPH_TEXCTL0_0 +
                                                       slot];
                                        SET_MASK(
                                            *ctl,
                                            NV_PGRAPH_TEXCTL0_0_MIN_LOD_CLAMP,
                                            first);
                                        SET_MASK(
                                            *ctl,
                                            NV_PGRAPH_TEXCTL0_0_MAX_LOD_CLAMP,
                                            last);
                                        SET_MASK(
                                            *ctl,
                                            NV_PGRAPH_TEXCTL0_0_MAX_ANISOTROPY,
                                            af + 1);
                                        pg->regs_[NV_PGRAPH_TEXFILTER0 + slot] =
                                            min << 16 | 2 << 24 | 96 |
                                            (signedHILO ? 0xf0000000u : 0);
                                        pg->regs_[NV_PGRAPH_TEXADDRESS0 +
                                                  slot] = address |
                                                          address << 8 |
                                                          address << 16;
                                        pg->regs_[NV_PGRAPH_BORDERCOLOR0 +
                                                  slot] = 0xff128989;
                                        pg->regs_[NV_PGRAPH_SHADERPROG] =
                                            (volume ?
                                                 PS_TEXTUREMODES_PROJECT3D :
                                                 PS_TEXTUREMODES_PROJECT2D)
                                            << (stage * 5);
                                        unsigned length = 0;
                                        for (unsigned level = 0; level <= last;
                                             level++)
                                            length +=
                                                4 *
                                                MAX(1u, physical[0] >> level) *
                                                MAX(1u, physical[1] >> level) *
                                                MAX(1u, physical[2] >> level);
                                        if (rectangle)
                                            length = 64 * core[1];
                                        cpu_write(8192, length);
                                        memset(state->vram_ptr + 8192, 0xd3,
                                               length);
                                        unsigned offset = 0;
                                        for (unsigned level = 0; level <= last;
                                             level++) {
                                            unsigned w = MAX(1u, physical[0] >>
                                                                     level),
                                                     h = MAX(1u, physical[1] >>
                                                                     level),
                                                     d = MAX(1u, physical[2] >>
                                                                     level);
                                            for (unsigned z = 0; z < d; z++)
                                                for (unsigned y = 0; y < h; y++)
                                                    for (unsigned x = 0; x < w;
                                                         x++)
                                                        stl_le_p(
                                                            state->vram_ptr +
                                                                8192 + offset +
                                                                (rectangle ?
                                                                     y * 64 +
                                                                         x * 4 :
                                                                     4 * volume_mip_morton(
                                                                             x,
                                                                             y,
                                                                             z,
                                                                             w,
                                                                             h,
                                                                             d)),
                                                            hilo16_volume_word(
                                                                x, y, z, 0,
                                                                level));
                                            offset += rectangle ? length :
                                                                  4 * w * h * d;
                                        }
                                        assert(offset == length);
                                        if (rectangle) {
                                            dma_a.limit = 4096 + length - 2;
                                            pg->texture_dirty[stage] = true;
                                            assert(
                                                ![adapter
                                                    prepareWithError:&error] &&
                                                pg->texture_dirty[stage]);
                                            shortDMA++;
                                        }

                                        dma_a.limit = 4096 + length - 1;
                                        NV2AMetalPGRAPHTextureSnapshot
                                            *original = prepare();
                                        finish();
                                        NSData *wire = [original
                                            snapshotWithCommands:surfaces
                                                                     .commands
                                                           error:&error];
                                        require(wire != nil, error);
                                        NV2AMetalPGRAPHTextureSnapshot
                                            *restored =
                                                [[NV2AMetalPGRAPHTextureSnapshot
                                                    alloc]
                                                    initWithSnapshot:wire
                                                            commands:
                                                                surfaces
                                                                    .commands
                                                               error:&error];
                                        require(restored != nil, error);
                                        NSData *again = [restored
                                            snapshotWithCommands:surfaces
                                                                     .commands
                                                           error:&error];
                                        require(again != nil, error);
                                        assert([again isEqualToData:wire]);
                                        cpu_write(8192, length);
                                        memset(state->vram_ptr + 8192, 0x5b,
                                               length);
                                        captures++;
                                        for (NV2AMetalPGRAPHTextureSnapshot
                                                 *snapshot in
                                             @[ original, restored ])
                                            for (unsigned direction = 0;
                                                 direction < (volume ? 6u : 4u);
                                                 direction++)
                                                for (unsigned center = 0;
                                                     center < 2; center++)
                                                    for (unsigned qp =
                                                             mode == 2 ? 3 :
                                                             mode == 0 ? 1 :
                                                                         0;
                                                         qp <
                                                         (mode == 0 ?
                                                              2u :
                                                              ARRAY_SIZE(
                                                                  qProfiles));
                                                         qp++)
                                                        for (unsigned
                                                                 dependent = 0;
                                                             dependent <
                                                             (stage ? 1u : 2u);
                                                             dependent++) {
                                                            NV2AMetalPixelUniforms
                                                                u = {};
                                                            NV2AMetalPixelTexture
                                                                bindings
                                                                    [4] = {};
                                                            require(
                                                                [snapshot
                                                                    applyToUniforms:
                                                                        &u
                                                                           textures:
                                                                               bindings
                                                                              error:
                                                                                  &
                                                                                  error],
                                                                error);
                                                            assert(
                                                                u.hilo16_mask ==
                                                                    (1u
                                                                     << stage) &&
                                                                u.textures[stage]
                                                                        .signed_channels ==
                                                                    (signedHILO ?
                                                                         15u :
                                                                         0u) &&
                                                                u.textures[stage]
                                                                        .sampling
                                                                        .anisotropy ==
                                                                    requested &&
                                                                u.textures[stage]
                                                                        .sampling
                                                                        .lod_bias ==
                                                                    .375f);
                                                            id<MTLTexture> texture =
                                                                bindings[stage]
                                                                    .texture;
                                                            for (unsigned axis =
                                                                     0;
                                                                 axis <
                                                                 (volume ? 3u :
                                                                           2u);
                                                                 axis++) {
                                                                unsigned dimension =
                                                                    axis == 0 ?
                                                                        texture
                                                                            .width :
                                                                    axis == 1 ?
                                                                        texture
                                                                            .height :
                                                                        texture
                                                                            .depth;
                                                                assert(
                                                                    dimension ==
                                                                    MAX(1u,
                                                                        physical[axis] >>
                                                                            first));
                                                            }
                                                            assert(
                                                                texture
                                                                    .mipmapLevelCount ==
                                                                last - first +
                                                                    1);
                                                            if (rectangle &&
                                                                !stage && !af &&
                                                                !filter && !a &&
                                                                !direction &&
                                                                !center &&
                                                                !qp &&
                                                                !dependent) {
                                                                id<MTLBuffer> raw =
                                                                    read_subresource(
                                                                        texture,
                                                                        0, 0);
                                                                finish();
                                                                for (unsigned
                                                                         y = 0;
                                                                     y <
                                                                     core[1];
                                                                     y++)
                                                                    for (
                                                                        unsigned
                                                                            x = 0;
                                                                        x <
                                                                        core[0];
                                                                        x++) {
                                                                        uint32_t word =
                                                                            hilo16_volume_word(
                                                                                x,
                                                                                y,
                                                                                0,
                                                                                0,
                                                                                0);
                                                                        const float expected[] = {
                                                                            hilo16_word_component(
                                                                                word,
                                                                                0,
                                                                                signedHILO),
                                                                            hilo16_word_component(
                                                                                word,
                                                                                1,
                                                                                signedHILO),
                                                                            hilo16_word_component(
                                                                                word,
                                                                                1,
                                                                                signedHILO),
                                                                            1
                                                                        };
                                                                        const float *actual =
                                                                            (const float
                                                                                 *)((const uint8_t
                                                                                         *)raw
                                                                                        .contents +
                                                                                    y * 256 +
                                                                                    x * 16);
                                                                        assert(!memcmp(
                                                                            actual,
                                                                            expected,
                                                                            sizeof(
                                                                                expected)));
                                                                        rawTexels++;
                                                                    }
                                                            }
                                                            u.surface_scale[0] =
                                                                u.surface_scale
                                                                    [1] = scale;
                                                            u.smooth_shading =
                                                                1;
                                                            u.clip_range[1] =
                                                                u.clip_range
                                                                    [3] = 65535;
                                                            /* Captured clip
                                                             * regions are
                                                             * already in host
                                                             * pixels. */
                                                            u.clip_regions[0]
                                                                          [2] =
                                                                u.clip_regions
                                                                    [0][3] =
                                                                    4 * scale;
                                                            u.combiner
                                                                .shader_stage_program =
                                                                (volume ?
                                                                     PS_TEXTUREMODES_PROJECT3D :
                                                                     PS_TEXTUREMODES_PROJECT2D)
                                                                << (stage * 5);
                                                            unsigned output =
                                                                stage;
                                                            if (dependent) {
                                                                u.combiner
                                                                    .shader_stage_program |=
                                                                    PS_TEXTUREMODES_DOTPRODUCT
                                                                        << 5 |
                                                                    PS_TEXTUREMODES_DOT_ST
                                                                        << 10;
                                                                u.other_stage_input =
                                                                    PS_DOTMAPPING_HILO_1 |
                                                                    PS_DOTMAPPING_HILO_1
                                                                        << 4;
                                                                u.textures[1]
                                                                    .dimension =
                                                                    u.textures[2]
                                                                        .dimension =
                                                                        2;
                                                                u.textures[2]
                                                                    .scale = 1;
                                                                u.textures[2]
                                                                    .sampling
                                                                    .enabled =
                                                                    1;
                                                                u.textures[2]
                                                                    .sampling
                                                                    .min_linear =
                                                                    u.textures[2]
                                                                        .sampling
                                                                        .mag_linear =
                                                                        1;
                                                                u.textures[2]
                                                                    .sampling
                                                                    .anisotropy =
                                                                    1;
                                                                for (unsigned
                                                                         axis =
                                                                             0;
                                                                     axis < 3;
                                                                     axis++)
                                                                    u.textures[2]
                                                                        .sampling
                                                                        .address
                                                                            [axis] =
                                                                        3;
                                                                bindings[2]
                                                                    .texture =
                                                                    lookup;
                                                                bindings[2]
                                                                    .sampler =
                                                                    sampler;
                                                                output = 2;
                                                            }
                                                            u.combiner
                                                                .final_inputs
                                                                    [0] =
                                                                PS_REGISTER_T0 +
                                                                output;
                                                            u.combiner
                                                                .final_inputs
                                                                    [1] =
                                                                (PS_REGISTER_T0 +
                                                                     output |
                                                                 PS_CHANNEL_ALPHA)
                                                                << 8;
                                                            double q =
                                                                qProfiles[qp]
                                                                         [0];
                                                            const double *dq =
                                                                &qProfiles[qp]
                                                                          [1];
                                                            double gradients[2]
                                                                            [3],
                                                                origin[3] = {
                                                                    .421875,
                                                                    .609375,
                                                                    .328125
                                                                };
                                                            unsigned major =
                                                                direction & 1;
                                                            for (unsigned axis =
                                                                     0;
                                                                 axis < 3;
                                                                 axis++) {
                                                                unsigned dimension = MAX(
                                                                    1u,
                                                                    physical[axis] >>
                                                                        first);
                                                                gradients[major][axis] =
                                                                    directions
                                                                        [direction]
                                                                        [0]
                                                                        [axis] /
                                                                    dimension;
                                                                gradients[1 -
                                                                          major][axis] =
                                                                    directions
                                                                        [direction]
                                                                        [1]
                                                                        [axis] /
                                                                    dimension;
                                                            }
                                                            if (center)
                                                                origin[volume ?
                                                                           2 :
                                                                           1] =
                                                                    -.046875;
                                                            if (!volume)
                                                                origin[2] = gradients
                                                                    [0]
                                                                    [2] = gradients
                                                                        [1][2] =
                                                                            0;
                                                            NV2AMetalVertex
                                                                vertices
                                                                    [6] = {};
                                                            const float
                                                                xy[][2] = {
                                                                    { -1, 1 },
                                                                    { 1, 1 },
                                                                    { -1, -1 },
                                                                    { 1, 1 },
                                                                    { 1, -1 },
                                                                    { -1, -1 }
                                                                };
                                                            for (unsigned j = 0;
                                                                 j < 6; j++) {
                                                                vertices[j]
                                                                    .clip[0] =
                                                                    xy[j][0];
                                                                vertices[j]
                                                                    .clip[1] =
                                                                    xy[j][1];
                                                                vertices[j]
                                                                    .clip[2] =
                                                                    .5f;
                                                                vertices[j]
                                                                    .clip[3] =
                                                                    1;
                                                                const float plane
                                                                    [3][4] = {
                                                                        { 0, 0,
                                                                          .5f,
                                                                          1 },
                                                                        { 4, 0,
                                                                          .5f,
                                                                          1 },
                                                                        { 0, 4,
                                                                          .5f,
                                                                          1 }
                                                                    };
                                                                memcpy(
                                                                    vertices[j]
                                                                        .plane,
                                                                    plane,
                                                                    sizeof(
                                                                        plane));
                                                                for (unsigned
                                                                         axis =
                                                                             0;
                                                                     axis <
                                                                     (volume ?
                                                                          3u :
                                                                          2u);
                                                                     axis++) {
                                                                    double coordinate =
                                                                        origin
                                                                            [axis] +
                                                                        2 *
                                                                            xy[j]
                                                                              [0] *
                                                                            gradients
                                                                                [0]
                                                                                [axis] -
                                                                        2 *
                                                                            xy[j]
                                                                              [1] *
                                                                            gradients
                                                                                [1]
                                                                                [axis];
                                                                    double numerator =
                                                                        coordinate *
                                                                        q;
                                                                    vertices[j].texcoord
                                                                        [stage]
                                                                        [axis] =
                                                                        border ?
                                                                            (numerator *
                                                                                 physical
                                                                                     [axis] -
                                                                             4) /
                                                                                core[axis] :
                                                                        rectangle ?
                                                                            numerator *
                                                                                physical
                                                                                    [axis] :
                                                                            numerator;
                                                                }
                                                                vertices[j]
                                                                    .texcoord
                                                                        [stage]
                                                                        [3] =
                                                                    q +
                                                                    2 *
                                                                        xy[j]
                                                                          [0] *
                                                                        dq[0] -
                                                                    2 *
                                                                        xy[j]
                                                                          [1] *
                                                                        dq[1];
                                                                const float dotS
                                                                    [] = { .5f,
                                                                           .25f,
                                                                           .125f,
                                                                           1 },
                                                                dotT[] = {
                                                                    .25f, .5f,
                                                                    .125f, 1
                                                                };
                                                                if (dependent) {
                                                                    memcpy(
                                                                        vertices[j]
                                                                            .texcoord
                                                                                [1],
                                                                        dotS,
                                                                        sizeof(
                                                                            dotS));
                                                                    memcpy(
                                                                        vertices[j]
                                                                            .texcoord
                                                                                [2],
                                                                        dotT,
                                                                        sizeof(
                                                                            dotT));
                                                                }
                                                            }
                                                            id<MTLBuffer> out =
                                                                hilo16_volume_draw(
                                                                    shader,
                                                                    target, &u,
                                                                    bindings,
                                                                    vertices);
                                                            for (unsigned py =
                                                                     0;
                                                                 py < 4 * scale;
                                                                 py++)
                                                                for (unsigned
                                                                         px = 0;
                                                                     px <
                                                                     4 * scale;
                                                                     px++) {
                                                                    double c[3],
                                                                        component
                                                                            [3],
                                                                        pixelGradient
                                                                            [2]
                                                                            [3];
                                                                    unsigned
                                                                        taps =
                                                                            0;
                                                                    double
                                                                        x = (px +
                                                                             .5) /
                                                                                scale -
                                                                            2,
                                                                        y = (py +
                                                                             .5) /
                                                                                scale -
                                                                            2;
                                                                    hilo16_projected_coordinate(
                                                                        origin,
                                                                        gradients,
                                                                        q, dq,
                                                                        x, y,
                                                                        c);
                                                                    // Finite
                                                                    // differences
                                                                    // across
                                                                    // each
                                                                    // pixel's
                                                                    // row/column
                                                                    // in its
                                                                    // 2x2 quad.
                                                                    for (
                                                                        unsigned
                                                                            screen =
                                                                                0;
                                                                        screen <
                                                                        2;
                                                                        screen++) {
                                                                        double low
                                                                            [3],
                                                                            high[3];
                                                                        double qx =
                                                                            screen ?
                                                                                x :
                                                                                ((px &
                                                                                  ~1u) +
                                                                                 .5) / scale -
                                                                                    2;
                                                                        double qy =
                                                                            screen ?
                                                                                ((py &
                                                                                  ~1u) +
                                                                                 .5) / scale -
                                                                                    2 :
                                                                                y;
                                                                        hilo16_projected_coordinate(
                                                                            origin,
                                                                            gradients,
                                                                            q,
                                                                            dq,
                                                                            qx,
                                                                            qy,
                                                                            low);
                                                                        hilo16_projected_coordinate(
                                                                            origin,
                                                                            gradients,
                                                                            q,
                                                                            dq,
                                                                            qx +
                                                                                !screen /
                                                                                    (double)
                                                                                        scale,
                                                                            qy +
                                                                                screen /
                                                                                    (double)
                                                                                        scale,
                                                                            high);
                                                                        for (
                                                                            unsigned
                                                                                axis =
                                                                                    0;
                                                                            axis <
                                                                            3;
                                                                            axis++)
                                                                            pixelGradient
                                                                                [screen]
                                                                                [axis] =
                                                                                    high[axis] -
                                                                                    low[axis];
                                                                    }
                                                                    for (
                                                                        unsigned
                                                                            k = 0;
                                                                        k < 3;
                                                                        k++) {
                                                                        component[k] = hilo16_gradient_reference(
                                                                            c,
                                                                            pixelGradient,
                                                                            physical,
                                                                            first,
                                                                            last,
                                                                            volume,
                                                                            address,
                                                                            min,
                                                                            2,
                                                                            requested,
                                                                            .375,
                                                                            k,
                                                                            border,
                                                                            signedHILO,
                                                                            &taps);
                                                                        if (qp <
                                                                            3)
                                                                            assert(
                                                                                taps ==
                                                                                requested);
                                                                    }
                                                                    assert(
                                                                        taps >=
                                                                            1 &&
                                                                        taps <=
                                                                            requested);
                                                                    pixelTaps
                                                                        [taps -
                                                                         1]++;
                                                                    double
                                                                        hi = component
                                                                            [0],
                                                                        lo = component
                                                                            [1];
                                                                    double normalZ =
                                                                        signedHILO ?
                                                                            sqrt(MAX(
                                                                                0.0,
                                                                                1 -
                                                                                    hi *
                                                                                        hi -
                                                                                    lo *
                                                                                        lo)) :
                                                                            1;
                                                                    double
                                                                        lookupS = MAX(
                                                                            .0625,
                                                                            MIN(.9375,
                                                                                .5 * hi +
                                                                                    .25 *
                                                                                        lo +
                                                                                    .125 *
                                                                                        normalZ)),
                                                                        lookupT = MAX(
                                                                            .0625,
                                                                            MIN(.9375,
                                                                                .25 * hi +
                                                                                    .5 *
                                                                                        lo +
                                                                                    .125 *
                                                                                        normalZ));
                                                                    double factor =
                                                                        signedHILO ?
                                                                            65536.0 /
                                                                                65535 :
                                                                            1;
                                                                    const double expected[] = {
                                                                        dependent ?
                                                                            lookupS :
                                                                            MAX(0.0,
                                                                                MIN(1.0,
                                                                                    hi *
                                                                                        factor)),
                                                                        dependent ?
                                                                            lookupT :
                                                                            MAX(0.0,
                                                                                MIN(1.0,
                                                                                    lo *
                                                                                        factor)),
                                                                        dependent ?
                                                                            .2 :
                                                                            MAX(0.0,
                                                                                MIN(1.0,
                                                                                    lo *
                                                                                        factor)),
                                                                        dependent ?
                                                                            .75 :
                                                                            component
                                                                                [2]
                                                                    };
                                                                    const float *actual =
                                                                        (const float
                                                                             *)((const uint8_t
                                                                                     *)out
                                                                                    .contents +
                                                                                py *
                                                                                    256 +
                                                                                px *
                                                                                    16);
                                                                    for (
                                                                        unsigned
                                                                            k = 0;
                                                                        k < 4;
                                                                        k++) {
                                                                        if (!isfinite(
                                                                                actual
                                                                                    [k]) ||
                                                                            fabs(
                                                                                actual
                                                                                    [k] -
                                                                                expected
                                                                                    [k]) >
                                                                                .000003) {
                                                                            fprintf(
                                                                                stderr,
                                                                                "projective mode%u qp%u Q%.9g ",
                                                                                mode,
                                                                                qp,
                                                                                q);
                                                                            fprintf(
                                                                                stderr,
                                                                                "HI"
                                                                                "LO"
                                                                                " g"
                                                                                "ra"
                                                                                "di"
                                                                                "en"
                                                                                "t "
                                                                                "si"
                                                                                "gn"
                                                                                "ed"
                                                                                "%u"
                                                                                " s"
                                                                                "ha"
                                                                                "pe"
                                                                                "%u"
                                                                                " b"
                                                                                "or"
                                                                                "de"
                                                                                "r%"
                                                                                "u "
                                                                                "st"
                                                                                "ag"
                                                                                "e%"
                                                                                "u "
                                                                                "fi"
                                                                                "rs"
                                                                                "t%"
                                                                                "u "
                                                                                "AF"
                                                                                "%u"
                                                                                " m"
                                                                                "in"
                                                                                "%u"
                                                                                " a"
                                                                                "dd"
                                                                                "r%"
                                                                                "u "
                                                                                "di"
                                                                                "re"
                                                                                "ct"
                                                                                "io"
                                                                                "n%"
                                                                                "u "
                                                                                "ce"
                                                                                "nt"
                                                                                "er"
                                                                                "%u"
                                                                                " d"
                                                                                "ep"
                                                                                "%u"
                                                                                " p"
                                                                                "ix"
                                                                                "el"
                                                                                "%u"
                                                                                ",%"
                                                                                "u "
                                                                                "ch"
                                                                                "an"
                                                                                "ne"
                                                                                "l%"
                                                                                "u:"
                                                                                " %"
                                                                                ".9"
                                                                                "g "
                                                                                "ex"
                                                                                "pe"
                                                                                "ct"
                                                                                "ed"
                                                                                " %"
                                                                                ".9"
                                                                                "g"
                                                                                "\n",
                                                                                signedHILO,
                                                                                shape,
                                                                                border,
                                                                                stage,
                                                                                first,
                                                                                requested,
                                                                                min,
                                                                                address,
                                                                                direction,
                                                                                center,
                                                                                dependent,
                                                                                px,
                                                                                py,
                                                                                k,
                                                                                actual
                                                                                    [k],
                                                                                expected
                                                                                    [k]);
                                                                            abort();
                                                                        }
                                                                        channels++;
                                                                    }
                                                                }
                                                            draws++;
                                                            profileDraws[qp]++;
                                                            dotDraws +=
                                                                dependent;
                                                            tapDraws[af]++;
                                                            directionDraws
                                                                [direction]++;
                                                            majorDraws[major]++;
                                                        }
                                    }
                                }
    dma_a = oldDMA;
    assert(rawTexels == (rectangle ? 428u : 0u) &&
           shortDMA == (rectangle ? 216u : 0u));
    unsigned expectedCaptures = rectangle ? 216 : 1152;
    unsigned expectedDraws = rectangle ? 31104 : mode == 2 ? 103680 : 34560;
    assert(captures == expectedCaptures && draws == expectedDraws &&
           channels == draws * 64 * scale * scale && dotDraws == draws / 3);
    for (unsigned i = 0; i < 3; i++)
        assert(tapDraws[i] == expectedDraws / 3);
    for (unsigned i = 0; i < 6; i++) {
        unsigned expectedDirection =
            rectangle ? (i < 4 ? 7776 : 0) :
                        (i < 4 ? 6912 : 3456) * (mode == 2 ? 3 : 1);
        assert(directionDraws[i] == expectedDirection);
        unsigned expectedProfile = mode == 0 ? (i == 1 ? draws : 0) :
                                   mode == 2 ? (i >= 3 ? draws / 3 : 0) :
                                               draws / 6;
        assert(profileDraws[i] == expectedProfile);
    }
    assert(majorDraws[0] == draws / 2 && majorDraws[1] == draws / 2);
    unsigned countedPixels = 0;
    for (unsigned i = 0; i < 8; i++)
        countedPixels += pixelTaps[i];
    assert(countedPixels == draws * 16 * scale * scale && pixelTaps[1] &&
           pixelTaps[3] && pixelTaps[7]);
    printf("Metal4 HILO16 gradients mode%u scale%u: %u captures/restores/exact "
           "resaves/%u "
           "draws/%u typed-Dot draws/%u channels; both screen axes PASS\n",
           mode, scale, captures, draws, dotDraws, channels);
    printf("Metal4 HILO16 raw texels%u/short-DMA rejections%u\n", rawTexels,
           shortDMA);
    printf("Metal4 HILO16 observed pixel taps1..8:");
    for (unsigned i = 0; i < 8; i++)
        printf(" %u", pixelTaps[i]);
    printf("\n");
}

static void volume_mip_chain_tests(void)
{
    NSError *error = nil;
    const unsigned formats[] = { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16,
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y16,
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8,
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8,
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8 };
    const unsigned logs[][3] = {
        { 3, 3, 3 }, { 0, 0, 3 }, { 3, 0, 1 }, { 1, 2, 4 }, { 0, 0, 0 }
    };
    unsigned cases = 0, texels = 0, rejected = 0;
    DMAObject oldDMA = dma_a;
    for (unsigned format = 0; format < ARRAY_SIZE(formats); format++)
        for (unsigned shape = 0; shape < ARRAY_SIZE(logs); shape++)
            for (unsigned clamp = 0; clamp < 4; clamp++) {
                @autoreleasepool {
                    PGRAPHState *pg = &state->pgraph;
                    for (unsigned i = 0; i < 4; i++)
                        pg->regs_[NV_PGRAPH_TEXCTL0_0 + i * 4] = 0;
                    pg->regs_[NV_PGRAPH_SHADERPROG] = 0;
                    unsigned stage = cases % 4, slot = stage * 4;
                    registers(stage, formats[format], 4, 0, 4096, false);
                    unsigned full = MAX(logs[shape][0],
                                        MAX(logs[shape][1], logs[shape][2])) +
                                    1;
                    unsigned requested = clamp == 3 ? 2 : 15;
                    unsigned maxLOD = clamp == 2 ? 1 : 15;
                    unsigned levels = MIN(full, MIN(requested, maxLOD + 1));
                    unsigned first = clamp == 1 ? levels - 1 :
                                     clamp == 3 ? levels - 1 :
                                                  0;
                    uint32_t *fmt = &pg->regs_[NV_PGRAPH_TEXFMT0 + slot];
                    SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_BASE_SIZE_U,
                             logs[shape][0]);
                    SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_BASE_SIZE_V,
                             logs[shape][1]);
                    SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_BASE_SIZE_P,
                             logs[shape][2]);
                    SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_DIMENSIONALITY, 3);
                    SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_MIPMAP_LEVELS, requested);
                    uint32_t *ctl = &pg->regs_[NV_PGRAPH_TEXCTL0_0 + slot];
                    SET_MASK(*ctl, NV_PGRAPH_TEXCTL0_0_MIN_LOD_CLAMP,
                             clamp == 1 || clamp == 3 ? 15 : 0);
                    SET_MASK(*ctl, NV_PGRAPH_TEXCTL0_0_MAX_LOD_CLAMP, maxLOD);
                    pg->regs_[NV_PGRAPH_SHADERPROG] = PS_TEXTUREMODES_PROJECT3D
                                                      << (5 * stage);
                    if (format == 4)
                        pg->regs_[NV_PGRAPH_TEXFILTER0 + slot] |=
                            NV_PGRAPH_TEXFILTER0_RSIGNED |
                            NV_PGRAPH_TEXFILTER0_GSIGNED |
                            NV_PGRAPH_TEXFILTER0_BSIGNED |
                            NV_PGRAPH_TEXFILTER0_ASIGNED;
                    unsigned bpp = format == 1 ? 2 : format == 2 ? 1 : 4;
                    unsigned length = 0;
                    for (unsigned level = 0; level < levels; level++)
                        length += bpp * MAX(1u, 1u << logs[shape][0] >> level) *
                                  MAX(1u, 1u << logs[shape][1] >> level) *
                                  MAX(1u, 1u << logs[shape][2] >> level);
                    cpu_write(8192, length);
                    unsigned offset = 0;
                    for (unsigned level = 0; level < levels; level++) {
                        unsigned w = MAX(1u, (1u << logs[shape][0]) >> level),
                                 h = MAX(1u, (1u << logs[shape][1]) >> level),
                                 d = MAX(1u, (1u << logs[shape][2]) >> level);
                        for (unsigned z = 0; z < d; z++)
                            for (unsigned y = 0; y < h; y++)
                                for (unsigned x = 0; x < w; x++) {
                                    uint8_t *dst =
                                        state->vram_ptr + 8192 + offset +
                                        bpp *
                                            volume_mip_morton(x, y, z, w, h, d);
                                    unsigned code =
                                        x + 3 * y + 5 * z + 7 * level;
                                    if (format == 0)
                                        stl_le_p(dst,
                                                 0x1289e237 ^ code * 0x10003u);
                                    else if (format == 1)
                                        stw_le_p(
                                            dst,
                                            (uint16_t)(0x1289 ^ code * 40503u));
                                    else if (format == 2)
                                        *dst = (17 + 13 * x + 23 * y + 37 * z +
                                                43 * level) &
                                               255;
                                    else
                                        for (unsigned k = 0; k < 4; k++)
                                            dst[k] =
                                                (17 + 13 * x + 23 * y + 37 * z +
                                                 43 * level + 71 * k) &
                                                255;
                                }
                        offset += bpp * w * h * d;
                    }
                    assert(offset == length);
                    dma_a.limit = 4096 + length - 1;
                    NV2AMetalPGRAPHTextureSnapshot *original = prepare();
                    finish();
                    NSData *wire =
                        [original snapshotWithCommands:surfaces.commands
                                                 error:&error];
                    require(wire != nil, error);
                    NV2AMetalPGRAPHTextureSnapshot *restored =
                        [[NV2AMetalPGRAPHTextureSnapshot alloc]
                            initWithSnapshot:wire
                                    commands:surfaces.commands
                                       error:&error];
                    require(restored != nil, error);
                    cpu_write(8192, length);
                    memset(state->vram_ptr + 8192, 0x5b, length);
                    for (NV2AMetalPGRAPHTextureSnapshot *snapshot in
                         @[ original, restored ]) {
                        NV2AMetalPixelUniforms u = { 0 };
                        NV2AMetalPixelTexture bindings[4] = {};
                        require([snapshot applyToUniforms:&u
                                                 textures:bindings
                                                    error:&error],
                                error);
                        id<MTLTexture> texture = bindings[stage].texture;
                        assert(texture.textureType == MTLTextureType3D &&
                               texture.mipmapLevelCount == levels - first &&
                               texture.width ==
                                   MAX(1u, (1u << logs[shape][0]) >> first) &&
                               texture.height ==
                                   MAX(1u, (1u << logs[shape][1]) >> first) &&
                               texture.depth ==
                                   MAX(1u, (1u << logs[shape][2]) >> first));
                        assert(u.hilo16_mask ==
                               (format == 0 ? 1u << stage : 0));
                        assert(u.textures[stage].signed_channels ==
                               (format == 4 ? 15u : 0u));
                        for (unsigned level = first; level < levels; level++) {
                            unsigned w = MAX(1u,
                                             (1u << logs[shape][0]) >> level),
                                     h = MAX(1u,
                                             (1u << logs[shape][1]) >> level),
                                     d = MAX(1u,
                                             (1u << logs[shape][2]) >> level);
                            id<MTLBuffer> out =
                                read_subresource(texture, level - first, 0);
                            finish();
                            NSUInteger row = (w * 16 + 255) & ~255u;
                            for (unsigned z = 0; z < d; z++)
                                for (unsigned y = 0; y < h; y++)
                                    for (unsigned x = 0; x < w; x++) {
                                        unsigned code =
                                            x + 3 * y + 5 * z + 7 * level;
                                        float expected[4];
                                        if (format == 0) {
                                            uint32_t word =
                                                0x1289e237 ^ code * 0x10003u;
                                            expected[0] =
                                                (word >> 16) / 65535.0;
                                            expected[1] = expected[2] =
                                                (word & 65535) / 65535.0;
                                            expected[3] = 1;
                                        } else if (format == 1 || format == 2) {
                                            float value =
                                                format == 1 ?
                                                    (uint16_t)(0x1289 ^
                                                               code * 40503u) /
                                                        65535.0 :
                                                    ((17 + 13 * x + 23 * y +
                                                      37 * z + 43 * level) &
                                                     255) /
                                                        255.0;
                                            expected[0] =
                                                format == 1 ? 1 : value;
                                            expected[1] = expected[2] = value;
                                            expected[3] = 1;
                                        } else
                                            signed_expected(
                                                0, format == 4 ? 15 : 0, level,
                                                0, x, y, z, NO, expected);
                                        const float *actual =
                                            (const float *)((const uint8_t *)
                                                                out.contents +
                                                            (z * h + y) * row +
                                                            x * 16);
                                        for (unsigned k = 0; k < 4; k++) {
                                            if (!isfinite(actual[k]) ||
                                                fabsf(actual[k] - expected[k]) >
                                                    .000001f) {
                                                fprintf(
                                                    stderr,
                                                    "3D mip format%u shape%u "
                                                    "clamp%u level%u "
                                                    "xyz%u,%u,%u channel%u: %g "
                                                    "expected %g\n",
                                                    format, shape, clamp, level,
                                                    x, y, z, k, actual[k],
                                                    expected[k]);
                                                abort();
                                            }
                                        }
                                        texels++;
                                    }
                        }
                    }
                    dma_a.limit--;
                    pg->texture_dirty[stage] = true;
                    assert(![adapter prepareWithError:&error] &&
                           pg->texture_dirty[stage]);
                    rejected++;
                    dma_a = oldDMA;
                    cases++;
                }
            }
    assert(cases == 100 && rejected == 100);
    printf("Metal4 full 3D mip chains: %u format/shape/clamp "
           "captures/restores/%u raw texels/%u short-DMA rejections PASS\n",
           cases, texels, rejected);
}

/* This checks the existing GL-compatible Gaussian approximation for both
 * kernel selectors. It does not establish the Xbox Quincunx coefficients. */
static void hilo16_convolution_tests(BOOL signedHILO)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:surfaces.commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:4
                                    height:4
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target =
        [surfaces.commands.device newTextureWithDescriptor:td];
    td.width = td.height = 8;
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> lookup =
        [surfaces.commands.device newTextureWithDescriptor:td];
    assert(target && lookup);
    float gradient[8][8][4];
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            const float value[] = { (x + .5f) / 8, (y + .5f) / 8, .2f, .75f };
            memcpy(gradient[y][x], value, sizeof(value));
        }
    [lookup replaceRegion:MTLRegionMake2D(0, 0, 8, 8)
              mipmapLevel:0
                withBytes:gradient
              bytesPerRow:sizeof(gradient[0])];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> sampler =
        [surfaces.commands.device newSamplerStateWithDescriptor:sd];
    assert(sampler);
    const struct {
        unsigned width, height;
        bool rectangle, border;
    } shapes[] = { { 8, 8, false, false }, { 8, 4, true, false },
                   { 2, 2, false, true },  { 16, 16, false, true },
                   { 1, 16, false, true }, { 16, 1, false, true } };
    const double profiles[][3] = { { .375, .625, 1 },   { .125, .875, .5 },
                                   { .8125, .1875, 2 }, { -.75, 1.25, 1 },
                                   { 1.5, -.5, .5 },    { .5, .5, 2 } };
    unsigned captures = 0, draws = 0, channels = 0, dependentDraws = 0;
    for (unsigned shape = 0; shape < ARRAY_SIZE(shapes); shape++) {
        unsigned width = shapes[shape].width, height = shapes[shape].height;
        bool rect = shapes[shape].rectangle, border = shapes[shape].border;
        unsigned physical[] = { border ? MAX(16u, 2 * width) : width,
                                border ? MAX(16u, 2 * height) : height, 1 };
        unsigned levels = rect ? 1 : 1 + ctz32(MAX(width, height));
        unsigned length = 0;
        for (unsigned level = 0; level < levels; level++)
            length += rect ? height * 48 :
                             MAX(1u, physical[0] >> level) *
                                 MAX(1u, physical[1] >> level) * 4;
        for (unsigned first = 0; first < (rect ? 1u : 2u); first++)
            for (unsigned stageIndex = 0; stageIndex < 2; stageIndex++)
                for (unsigned kernel = 1; kernel <= 2; kernel++)
                    for (unsigned mag = 1; mag <= 2; mag++)
                        for (unsigned address = 1; address <= 5; address++) {
                            @autoreleasepool {
                                unsigned stage = stageIndex * 3;
                                PGRAPHState *pg = &state->pgraph;
                                for (unsigned i = 0; i < 4; i++)
                                    pg->regs_[NV_PGRAPH_TEXCTL0_0 + i * 4] = 0;
                                pg->regs_[NV_PGRAPH_SHADERPROG] = 0;
                                registers(
                                    stage,
                                    rect ?
                                        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16 :
                                        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16,
                                    width, 48, 4096, false);
                                uint32_t *fmt =
                                    &pg->regs_[NV_PGRAPH_TEXFMT0 + stage * 4];
                                SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_BASE_SIZE_U,
                                         ctz32(width));
                                SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_BASE_SIZE_V,
                                         ctz32(height));
                                SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_MIPMAP_LEVELS,
                                         levels);
                                SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_BORDER_SOURCE,
                                         !border);
                                pg->regs_[NV_PGRAPH_TEXIMAGERECT0 + stage * 4] =
                                    width << 16 | height;
                                uint32_t *ctl =
                                    &pg->regs_[NV_PGRAPH_TEXCTL0_0 + stage * 4];
                                SET_MASK(*ctl,
                                         NV_PGRAPH_TEXCTL0_0_MIN_LOD_CLAMP,
                                         first);
                                SET_MASK(*ctl,
                                         NV_PGRAPH_TEXCTL0_0_MAX_LOD_CLAMP,
                                         levels - 1);
                                pg->regs_[NV_PGRAPH_TEXFILTER0 + stage * 4] =
                                    7 << 16 | mag << 24 | kernel << 13 |
                                    (signedHILO ? 0xf0000000u : 0);
                                pg->regs_[NV_PGRAPH_TEXADDRESS0 + stage * 4] =
                                    address | address << 8 | 3 << 16;
                                pg->regs_[NV_PGRAPH_BORDERCOLOR0 + stage * 4] =
                                    0xff128989;
                                cpu_write(8192, length);
                                memset(state->vram_ptr + 8192, 0xd3, length);
                                unsigned offset = 0;
                                for (unsigned level = 0; level < levels;
                                     level++) {
                                    unsigned w = MAX(1u, physical[0] >> level),
                                             h = MAX(1u, physical[1] >> level);
                                    for (unsigned y = 0; y < h; y++)
                                        for (unsigned x = 0; x < w; x++) {
                                            unsigned pos =
                                                rect ?
                                                    y * 48 + x * 4 :
                                                    offset +
                                                        4 * volume_mip_morton(
                                                                x, y, 0, w, h,
                                                                1);
                                            stl_le_p(
                                                state->vram_ptr + 8192 + pos,
                                                hilo16_volume_word(x, y, 0, 0,
                                                                   level));
                                        }
                                    offset += w * h * 4;
                                }
                                NV2AMetalPGRAPHTextureSnapshot *original =
                                    prepare();
                                finish();
                                NSData *wire = [original
                                    snapshotWithCommands:surfaces.commands
                                                   error:&error];
                                require(wire != nil, error);
                                NV2AMetalPGRAPHTextureSnapshot *restored =
                                    [[NV2AMetalPGRAPHTextureSnapshot alloc]
                                        initWithSnapshot:wire
                                                commands:surfaces.commands
                                                   error:&error];
                                require(restored != nil, error);
                                NSData *again = [restored
                                    snapshotWithCommands:surfaces.commands
                                                   error:&error];
                                require(again != nil, error);
                                assert([again isEqualToData:wire]);
                                cpu_write(8192, length);
                                memset(state->vram_ptr + 8192, 0x5b, length);
                                captures++;
                                for (NV2AMetalPGRAPHTextureSnapshot *snapshot in
                                     @[ original, restored ])
                                    for (unsigned profile = 0;
                                         profile < ARRAY_SIZE(profiles);
                                         profile++)
                                        for (unsigned dependent = 0;
                                             dependent < (stage ? 1u : 2u);
                                             dependent++) {
                                            NV2AMetalPixelUniforms u = {};
                                            NV2AMetalPixelTexture
                                                bindings[4] = {};
                                            require([snapshot
                                                        applyToUniforms:&u
                                                               textures:bindings
                                                                  error:&error],
                                                    error);
                                            unsigned vw = MAX(1u, physical[0] >>
                                                                      first),
                                                     vh = MAX(1u, physical[1] >>
                                                                      first);
                                            assert(
                                                u.hilo16_mask ==
                                                    (1u << stage) &&
                                                u.textures[stage].convolution ==
                                                    kernel &&
                                                u.textures[stage]
                                                        .signed_channels ==
                                                    (signedHILO ? 15u : 0u) &&
                                                bindings[stage].texture.width ==
                                                    vw &&
                                                bindings[stage]
                                                        .texture.height == vh &&
                                                bindings[stage]
                                                        .texture
                                                        .mipmapLevelCount ==
                                                    levels - first);
                                            u.surface_scale[0] =
                                                u.surface_scale[1] = 1;
                                            u.smooth_shading = 1;
                                            u.clip_range[1] = u.clip_range[3] =
                                                65535;
                                            u.clip_regions[0][2] =
                                                u.clip_regions[0][3] = 4;
                                            u.combiner.shader_stage_program =
                                                PS_TEXTUREMODES_PROJECT2D
                                                << (5 * stage);
                                            unsigned output = stage;
                                            if (dependent) {
                                                u.combiner
                                                    .shader_stage_program |=
                                                    PS_TEXTUREMODES_DOTPRODUCT
                                                        << 5 |
                                                    PS_TEXTUREMODES_DOT_ST
                                                        << 10;
                                                u.other_stage_input =
                                                    PS_DOTMAPPING_HILO_1 |
                                                    PS_DOTMAPPING_HILO_1 << 4;
                                                u.textures[1].dimension =
                                                    u.textures[2].dimension = 2;
                                                u.textures[2].scale = 1;
                                                u.textures[2].sampling.enabled =
                                                    1;
                                                u.textures[2]
                                                    .sampling.min_linear =
                                                    u.textures[2]
                                                        .sampling.mag_linear =
                                                        1;
                                                u.textures[2]
                                                    .sampling.anisotropy = 1;
                                                for (unsigned axis = 0;
                                                     axis < 3; axis++)
                                                    u.textures[2]
                                                        .sampling
                                                        .address[axis] = 3;
                                                bindings[2].texture = lookup;
                                                bindings[2].sampler = sampler;
                                                output = 2;
                                            }
                                            u.combiner.final_inputs[0] =
                                                PS_REGISTER_T0 + output;
                                            u.combiner.final_inputs[1] =
                                                (PS_REGISTER_T0 + output |
                                                 PS_CHANNEL_ALPHA)
                                                << 8;
                                            double q = profiles[profile][2];
                                            double dx =
                                                profile == 5 ?
                                                    q * 2.5 / vw *
                                                        (border ?
                                                             (double)physical
                                                                     [0] /
                                                                 width :
                                                             1) :
                                                    0;
                                            double dy =
                                                profile == 5 ?
                                                    q * 2.5 / vh *
                                                        (border ?
                                                             (double)physical
                                                                     [1] /
                                                                 height :
                                                             1) :
                                                    0;
                                            NV2AMetalVertex vertices[6] = {};
                                            const float xy[][2] = {
                                                { -1, 1 },  { 1, 1 },
                                                { -1, -1 }, { 1, 1 },
                                                { 1, -1 },  { -1, -1 }
                                            };
                                            for (unsigned j = 0; j < 6; j++) {
                                                vertices[j].clip[0] = xy[j][0];
                                                vertices[j].clip[1] = xy[j][1];
                                                vertices[j].clip[2] = .5f;
                                                vertices[j].clip[3] = 1;
                                                const float plane[3][4] = {
                                                    { 0, 0, .5f, 1 },
                                                    { 4, 0, .5f, 1 },
                                                    { 0, 4, .5f, 1 }
                                                };
                                                memcpy(vertices[j].plane, plane,
                                                       sizeof(plane));
                                                vertices[j].texcoord[stage][0] =
                                                    (profiles[profile][0] +
                                                     xy[j][0] * 2 * dx) *
                                                    (rect ? width : 1);
                                                vertices[j].texcoord[stage][1] =
                                                    (profiles[profile][1] -
                                                     xy[j][1] * 2 * dy) *
                                                    (rect ? height : 1);
                                                vertices[j].texcoord[stage][3] =
                                                    q;
                                                const float dotS[] = { .5f,
                                                                       .25f,
                                                                       .125f,
                                                                       1 },
                                                            dotT[] = { .25f,
                                                                       .5f,
                                                                       .125f,
                                                                       1 };
                                                memcpy(vertices[j].texcoord[1],
                                                       dotS, sizeof(dotS));
                                                memcpy(vertices[j].texcoord[2],
                                                       dotT, sizeof(dotT));
                                            }
                                            id<MTLBuffer> out =
                                                hilo16_volume_draw(
                                                    shader, target, &u,
                                                    bindings, vertices);
                                            for (unsigned py = 0; py < 4; py++)
                                                for (unsigned px = 0; px < 4;
                                                     px++) {
                                                    double s = profiles[profile]
                                                                       [0] +
                                                               (px + .5 - 2) *
                                                                   dx,
                                                           t = profiles[profile]
                                                                       [1] +
                                                               (py + .5 - 2) *
                                                                   dy;
                                                    if (border) {
                                                        s = (s * width + 4) /
                                                            physical[0];
                                                        t = (t * height + 4) /
                                                            physical[1];
                                                    }
                                                    double filtered[3] = {};
                                                    /* Pascal's 1,2,1 outer
                                                     * product gives integer tap
                                                     * weights summing to 16. */
                                                    for (int y = -1; y <= 1;
                                                         y++)
                                                        for (int x = -1; x <= 1;
                                                             x++)
                                                            for (unsigned k = 0;
                                                                 k < 3; k++)
                                                                filtered[k] +=
                                                                    (!border &&
                                                                             k ==
                                                                                 2 ?
                                                                         1 :
                                                                         hilo16_rect_level(
                                                                             (s +
                                                                              (double)x /
                                                                                  vw) /
                                                                                 q,
                                                                             (t +
                                                                              (double)y /
                                                                                  vh) /
                                                                                 q,
                                                                             0,
                                                                             physical,
                                                                             first,
                                                                             0,
                                                                             false,
                                                                             address,
                                                                             profile ==
                                                                                     5 ||
                                                                                 mag ==
                                                                                     2,
                                                                             k,
                                                                             border,
                                                                             signedHILO)) *
                                                                    (x == 0 ?
                                                                         2 :
                                                                         1) *
                                                                    (y == 0 ?
                                                                         2 :
                                                                         1) /
                                                                    16;
                                                    double hi = filtered[0],
                                                           lo = filtered[1];
                                                    double normalZ =
                                                        signedHILO ?
                                                            sqrt(MAX(
                                                                0.0,
                                                                1 - hi * hi -
                                                                    lo * lo)) :
                                                            1;
                                                    double lookupS =
                                                               .5 * hi +
                                                               .25 * lo +
                                                               .125 * normalZ,
                                                           lookupT =
                                                               .25 * hi +
                                                               .5 * lo +
                                                               .125 * normalZ;
                                                    const double expected[] = {
                                                        dependent ?
                                                            (signedHILO ?
                                                                 MAX(.0625,
                                                                     MIN(.9375,
                                                                         lookupS)) :
                                                                 lookupS) :
                                                            (signedHILO ?
                                                                 MAX(0.0,
                                                                     hi *
                                                                         65536 /
                                                                         65535) :
                                                                 hi),
                                                        dependent ?
                                                            (signedHILO ?
                                                                 MAX(.0625,
                                                                     MIN(.9375,
                                                                         lookupT)) :
                                                                 lookupT) :
                                                            (signedHILO ?
                                                                 MAX(0.0,
                                                                     lo *
                                                                         65536 /
                                                                         65535) :
                                                                 lo),
                                                        dependent ?
                                                            .2 :
                                                            (signedHILO ?
                                                                 MAX(0.0,
                                                                     lo *
                                                                         65536 /
                                                                         65535) :
                                                                 lo),
                                                        dependent ? .75 :
                                                                    filtered[2]
                                                    };
                                                    const float *actual =
                                                        (const float
                                                             *)((const uint8_t
                                                                     *)out
                                                                    .contents +
                                                                py * 256 +
                                                                px * 16);
                                                    for (unsigned k = 0; k < 4;
                                                         k++) {
                                                        if (!isfinite(
                                                                actual[k]) ||
                                                            fabs(actual[k] -
                                                                 expected[k]) >
                                                                (signedHILO ?
                                                                     .000002 :
                                                                     .00005)) {
                                                            fprintf(
                                                                stderr,
                                                                "HILO16 "
                                                                "convolution "
                                                                "shape%u "
                                                                "first%u "
                                                                "stage%u "
                                                                "kernel%u "
                                                                "mag%u "
                                                                "address%u "
                                                                "restore%d "
                                                                "profile%u "
                                                                "dependent%u "
                                                                "pixel%u,%u "
                                                                "channel%u: "
                                                                "%.9g expected "
                                                                "%.9g\n",
                                                                shape, first,
                                                                stage, kernel,
                                                                mag, address,
                                                                snapshot ==
                                                                    restored,
                                                                profile,
                                                                dependent, px,
                                                                py, k,
                                                                actual[k],
                                                                expected[k]);
                                                            abort();
                                                        }
                                                        channels++;
                                                    }
                                                }
                                            draws++;
                                            dependentDraws += dependent;
                                        }
                            }
                        }
    }
    assert(captures == 440 && draws == 7920 && dependentDraws == 2640 &&
           channels == 506880);
    printf("Metal4 %sHILO16 convolution: %u captures/restores/canonical "
           "resaves/%u draws/%u typed-dot draws/%u full-frame channels PASS\n",
           signedHILO ? "signed " : "", captures, draws, dependentDraws,
           channels);
}

/* Physical border storage follows the GL upload model: max(16,2*core)
 * with the logical origin four base-level texels into that storage. */
static void hilo16_physical_border_tests(BOOL signedHILO)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:surfaces.commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:4
                                    height:4
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target =
        [surfaces.commands.device newTextureWithDescriptor:td];
    td.width = td.height = 8;
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> lookup =
        [surfaces.commands.device newTextureWithDescriptor:td];
    assert(target && lookup);
    float gradient[8][8][4];
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            const float pixel[] = { (x + .5f) / 8, (y + .5f) / 8, .2f, .75f };
            memcpy(gradient[y][x], pixel, sizeof(pixel));
        }
    [lookup replaceRegion:MTLRegionMake2D(0, 0, 8, 8)
              mipmapLevel:0
                withBytes:gradient
              bytesPerRow:sizeof(gradient[0])];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> sampler =
        [surfaces.commands.device newSamplerStateWithDescriptor:sd];
    assert(sampler);

    unsigned captures = 0, draws = 0, channels = 0, rawTexels = 0;
    unsigned eightTapDraws = 0, shortDMA = 0, pointFaces[2] = {};
    DMAObject oldDMA = dma_a;
    // Dimension followed by the three logical log2 axes. Include thin tails
    // whose physical axes reach one before the largest axis finishes.
    const unsigned shapes[][4] = {
        { 2, 1, 1, 0 }, { 2, 2, 2, 0 }, { 2, 3, 3, 0 }, { 2, 4, 4, 0 },
        { 2, 0, 0, 0 }, { 2, 0, 4, 0 }, { 2, 4, 0, 0 }, { 2, 1, 4, 0 },
        { 2, 4, 1, 0 }, { 2, 2, 3, 0 }, { 2, 3, 2, 0 }, { 2, 0, 5, 0 },
        { 2, 5, 0, 0 }, { 3, 1, 1, 1 }, { 3, 2, 2, 2 }, { 3, 3, 3, 3 },
        { 3, 4, 4, 4 }, { 3, 0, 0, 0 }, { 3, 0, 1, 4 }, { 3, 4, 0, 1 },
        { 3, 1, 4, 0 }, { 3, 1, 2, 4 }, { 3, 4, 2, 1 }, { 3, 2, 4, 1 },
        { 3, 0, 1, 5 }, { 3, 5, 0, 1 },
    };
    for (unsigned volume = 0; volume < 2; volume++)
        for (unsigned shape = 13 * volume; shape < 13 * (volume + 1); shape++)
            for (unsigned range = 0; range < 3; range++)
                for (unsigned address = 1; address <= 5; address++)
                    for (unsigned profile = 0; profile < 17; profile++) {
                        @autoreleasepool {
                            assert(shapes[shape][0] == (volume ? 3u : 2u));
                            unsigned core[] = { 1u << shapes[shape][1],
                                                1u << shapes[shape][2],
                                                1u << shapes[shape][3] };
                            unsigned physical[] = {
                                MAX(16u, 2 * core[0]), MAX(16u, 2 * core[1]),
                                volume ? MAX(16u, 2 * core[2]) : 1
                            };
                            unsigned log =
                                MAX(shapes[shape][1],
                                    MAX(shapes[shape][2], shapes[shape][3]));
                            if ((!volume && (profile == 5 || profile == 6)) ||
                                (!log && range != 0))
                                continue;
                            unsigned first = range == 0 ? 0 :
                                             range == 1 ? 1 :
                                                          log;
                            unsigned last = log;
                            unsigned min =
                                profile >= 11 && profile <= 14 ? profile - 8 :
                                profile == 7 || profile == 8 || profile == 10 ||
                                        profile == 16 ?
                                                                 2 :
                                                                 1;
                            unsigned mag = min % 2 == 0 ? 2 : 1;
                            unsigned taps = profile >= 15 ? 8 : 1;
                            double major = taps == 8     ? 8 :
                                           profile >= 11 ? 1.5 :
                                           mag == 2      ? .5 :
                                                           0;
                            double minor = profile >= 11 ? 1 :
                                           mag == 2      ? .25 :
                                                           0;
                            double lod = taps == 8     ? 0 :
                                         profile >= 11 ? .5849625007211562 :
                                                         -1;
                            double center[3] = { 4 + core[0] * .375,
                                                 4 + core[1] * .625,
                                                 4 + core[2] * .375 };
                            if (profile >= 1 && profile <= 6) {
                                unsigned axis = (profile - 1) / 2;
                                center[axis] =
                                    profile % 2 ? 3.25 : 4 + core[axis] + .75;
                                pointFaces[volume] |= 1u << (profile - 1);
                            } else if (profile == 7 || profile == 8) {
                                for (unsigned axis = 0; axis < 3; axis++)
                                    center[axis] = profile == 7 ?
                                                       2.25 :
                                                       4 + core[axis] + 1.25;
                            } else if (profile == 9 || profile == 10) {
                                for (unsigned axis = 0; axis < 3; axis++)
                                    center[axis] = profile == 9 ?
                                                       -.5 :
                                                       physical[axis] + .5;
                            } else if (profile >= 11) {
                                center[0] = 3.75;
                                center[1] = 4 + core[1] + .25;
                                center[2] = 3.75;
                            }
                            double dx =
                                major * physical[0] /
                                (core[0] * MAX(1u, physical[0] >> first));
                            double dy =
                                minor * physical[1] /
                                (core[1] * MAX(1u, physical[1] >> first));
                            PGRAPHState *pg = &state->pgraph;
                            for (unsigned i = 0; i < 4; i++)
                                pg->regs_[NV_PGRAPH_TEXCTL0_0 + 4 * i] = 0;
                            registers(
                                0,
                                NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16,
                                core[0], 0, 4096, false);
                            uint32_t *fmt = &pg->regs_[NV_PGRAPH_TEXFMT0];
                            *fmt &= ~NV_PGRAPH_TEXFMT0_BORDER_SOURCE;
                            SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_BASE_SIZE_U,
                                     shapes[shape][1]);
                            SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_BASE_SIZE_V,
                                     shapes[shape][2]);
                            SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_BASE_SIZE_P,
                                     shapes[shape][3]);
                            SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_DIMENSIONALITY,
                                     volume ? 3 : 2);
                            SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_MIPMAP_LEVELS,
                                     log + 1);
                            uint32_t *ctl = &pg->regs_[NV_PGRAPH_TEXCTL0_0];
                            SET_MASK(*ctl, NV_PGRAPH_TEXCTL0_0_MIN_LOD_CLAMP,
                                     first);
                            SET_MASK(*ctl, NV_PGRAPH_TEXCTL0_0_MAX_LOD_CLAMP,
                                     last);
                            SET_MASK(*ctl, NV_PGRAPH_TEXCTL0_0_MAX_ANISOTROPY,
                                     taps == 8 ? 3 : 0);
                            pg->regs_[NV_PGRAPH_TEXFILTER0] =
                                min << 16 | mag << 24 |
                                (signedHILO ? 0xf0000000u : 0);
                            pg->regs_[NV_PGRAPH_TEXADDRESS0] =
                                address | address << 8 | address << 16;
                            pg->regs_[NV_PGRAPH_BORDERCOLOR0] = 0xff128989;
                            pg->regs_[NV_PGRAPH_SHADERPROG] =
                                volume ? PS_TEXTUREMODES_PROJECT3D :
                                         PS_TEXTUREMODES_PROJECT2D;
                            unsigned length = 0;
                            for (unsigned level = 0; level <= last; level++) {
                                length += 4 * MAX(1u, physical[0] >> level) *
                                          MAX(1u, physical[1] >> level) *
                                          MAX(1u, physical[2] >> level);
                            }
                            cpu_write(8192, length);
                            unsigned offset = 0;
                            for (unsigned level = 0; level <= last; level++) {
                                unsigned width = MAX(1u, physical[0] >> level),
                                         height = MAX(1u, physical[1] >> level),
                                         depth = MAX(1u, physical[2] >> level);
                                for (unsigned z = 0; z < depth; z++)
                                    for (unsigned y = 0; y < height; y++)
                                        for (unsigned x = 0; x < width; x++)
                                            stl_le_p(state->vram_ptr + 8192 +
                                                         offset +
                                                         4 * volume_mip_morton(
                                                                 x, y, z, width,
                                                                 height, depth),
                                                     hilo16_volume_word(
                                                         x, y, z, 0, level));
                                offset += 4 * width * height * depth;
                            }
                            assert(offset == length);
                            dma_a.limit = 4096 + length - 1;
                            NV2AMetalPGRAPHTextureSnapshot *original =
                                prepare();
                            finish();
                            NSData *wire =
                                [original snapshotWithCommands:surfaces.commands
                                                         error:&error];
                            require(wire != nil, error);
                            NV2AMetalPGRAPHTextureSnapshot *restored =
                                [[NV2AMetalPGRAPHTextureSnapshot alloc]
                                    initWithSnapshot:wire
                                            commands:surfaces.commands
                                               error:&error];
                            require(restored != nil, error);
                            if (signedHILO) {
                                NSData *again = [restored
                                    snapshotWithCommands:surfaces.commands
                                                   error:&error];
                                require(again != nil, error);
                                assert([again isEqualToData:wire]);
                            }

                            cpu_write(8192, length);
                            memset(state->vram_ptr + 8192, 0x5b, length);
                            for (NV2AMetalPGRAPHTextureSnapshot *snapshot in
                                 @[ original, restored ]) {
                                NV2AMetalPixelUniforms frozen = {};
                                NV2AMetalPixelTexture bindings[4] = {};
                                require([snapshot applyToUniforms:&frozen
                                                         textures:bindings
                                                            error:&error],
                                        error);
                                id<MTLTexture> texture = bindings[0].texture;
                                for (unsigned k = 0; k < 4; k++)
                                    assert(frozen.textures[0]
                                               .sampling.border_color[k] == 0);
                                assert(frozen.hilo16_mask == 1 &&
                                       frozen.textures[0].signed_channels ==
                                           (signedHILO ? 15u : 0u) &&
                                       texture.width ==
                                           MAX(1u, physical[0] >> first) &&
                                       texture.height ==
                                           MAX(1u, physical[1] >> first) &&
                                       texture.depth ==
                                           MAX(1u, physical[2] >> first) &&
                                       texture.mipmapLevelCount ==
                                           last - first + 1);
                                for (unsigned axis = 0; axis < 3; axis++) {
                                    assert(frozen.textures[0]
                                               .border_logical_size[axis] ==
                                           core[axis]);
                                    assert(frozen.textures[0]
                                               .border_inv_real_size[axis] ==
                                           1.f / (axis == 2 && !volume ?
                                                      16 :
                                                      physical[axis]));
                                }
                                if (address == 1 && profile == 0) {
                                    for (unsigned level = first; level <= last;
                                         level++) {
                                        unsigned width = MAX(1u, physical[0] >>
                                                                     level),
                                                 height = MAX(1u, physical[1] >>
                                                                      level),
                                                 depth = MAX(1u, physical[2] >>
                                                                     level);
                                        id<MTLBuffer> raw = read_subresource(
                                            texture, level - first, 0);
                                        finish();
                                        NSUInteger row =
                                            (width * 16 + 255) & ~255u;
                                        for (unsigned z = 0; z < depth; z++)
                                            for (unsigned y = 0; y < height;
                                                 y++)
                                                for (unsigned x = 0; x < width;
                                                     x++) {
                                                    uint32_t word =
                                                        hilo16_volume_word(
                                                            x, y, z, 0, level);
                                                    const float *actual =
                                                        (const float
                                                             *)((const uint8_t
                                                                     *)raw
                                                                    .contents +
                                                                (z * height +
                                                                 y) *
                                                                    row +
                                                                x * 16);
                                                    const float expected[] = {
                                                        hilo16_word_component(
                                                            word, 0,
                                                            signedHILO),
                                                        hilo16_word_component(
                                                            word, 1,
                                                            signedHILO),
                                                        hilo16_word_component(
                                                            word, 1,
                                                            signedHILO),
                                                        1
                                                    };
                                                    if (signedHILO)
                                                        assert(!memcmp(
                                                            actual, expected,
                                                            sizeof(expected)));
                                                    for (unsigned k = 0; k < 4;
                                                         k++)
                                                        assert(
                                                            isfinite(
                                                                actual[k]) &&
                                                            fabs(actual[k] -
                                                                 expected[k]) <
                                                                .000001);
                                                    rawTexels++;
                                                }
                                    }
                                }
                                for (unsigned dependent = 0; dependent < 2;
                                     dependent++) {
                                    NV2AMetalPixelUniforms u = frozen;
                                    u.combiner.shader_stage_program =
                                        volume ? PS_TEXTUREMODES_PROJECT3D :
                                                 PS_TEXTUREMODES_PROJECT2D;
                                    u.surface_scale[0] = u.surface_scale[1] = 1;
                                    u.smooth_shading = 1;
                                    u.clip_range[1] = u.clip_range[3] = 65535;
                                    u.clip_regions[0][2] =
                                        u.clip_regions[0][3] = 4;
                                    u.combiner.final_inputs[0] = PS_REGISTER_T0;
                                    u.combiner.final_inputs[1] =
                                        (PS_REGISTER_T0 | PS_CHANNEL_ALPHA)
                                        << 8;
                                    if (dependent) {
                                        u.combiner.shader_stage_program |=
                                            PS_TEXTUREMODES_DOTPRODUCT << 5 |
                                            PS_TEXTUREMODES_DOT_ST << 10;
                                        unsigned mapping =
                                            (profile + address + log) % 8;
                                        u.other_stage_input =
                                            mapping | mapping << 4;
                                        u.textures[1].dimension =
                                            u.textures[2].dimension = 2;
                                        u.textures[2].scale = 1;
                                        u.textures[2].sampling.enabled = 1;
                                        u.textures[2].sampling.min_linear =
                                            u.textures[2].sampling.mag_linear =
                                                1;
                                        u.textures[2].sampling.anisotropy = 1;
                                        for (unsigned axis = 0; axis < 3;
                                             axis++)
                                            u.textures[2]
                                                .sampling.address[axis] = 3;
                                        bindings[2].texture = lookup;
                                        bindings[2].sampler = sampler;
                                        u.combiner.final_inputs[0] =
                                            PS_REGISTER_T2;
                                        u.combiner.final_inputs[1] =
                                            (PS_REGISTER_T2 | PS_CHANNEL_ALPHA)
                                            << 8;
                                    }
                                    NV2AMetalVertex vertices[6] = {};
                                    const float xy[][2] = {
                                        { -1, 1 }, { 1, 1 },  { -1, -1 },
                                        { 1, 1 },  { 1, -1 }, { -1, -1 }
                                    };
                                    for (unsigned j = 0; j < 6; j++) {
                                        vertices[j].clip[0] = xy[j][0];
                                        vertices[j].clip[1] = xy[j][1];
                                        vertices[j].clip[2] = .5f;
                                        vertices[j].clip[3] = 1;
                                        const float plane[3][4] = {
                                            { 0, 0, .5f, 1 },
                                            { 4, 0, .5f, 1 },
                                            { 0, 4, .5f, 1 }
                                        };
                                        memcpy(vertices[j].plane, plane,
                                               sizeof(plane));
                                        vertices[j].texcoord[0][0] =
                                            (center[0] - 4) / core[0] +
                                            xy[j][0] * 2 * dx;
                                        vertices[j].texcoord[0][1] =
                                            (center[1] - 4) / core[1] -
                                            xy[j][1] * 2 * dy;
                                        vertices[j].texcoord[0][2] =
                                            volume ? (center[2] - 4) / core[2] :
                                                     0;
                                        vertices[j].texcoord[0][3] = 1;
                                        const float dotS[] = { .5f, .25f, .125f,
                                                               1 },
                                                    dotT[] = { .25f, .5f, .125f,
                                                               1 };
                                        memcpy(vertices[j].texcoord[1], dotS,
                                               sizeof(dotS));
                                        memcpy(vertices[j].texcoord[2], dotT,
                                               sizeof(dotT));
                                    }
                                    id<MTLBuffer> out = hilo16_volume_draw(
                                        shader, target, &u, bindings, vertices);
                                    for (unsigned py = 0; py < 4; py++)
                                        for (unsigned px = 0; px < 4; px++) {
                                            double x = center[0] / physical[0] +
                                                       (px + .5 - 2) * dx *
                                                           core[0] /
                                                           physical[0];
                                            double y = center[1] / physical[1] +
                                                       (py + .5 - 2) * dy *
                                                           core[1] /
                                                           physical[1];
                                            double z =
                                                volume ?
                                                    center[2] / physical[2] :
                                                    .5;
                                            double hi = hilo16_rect_reference(
                                                x, y, z,
                                                dx * core[0] / physical[0], lod,
                                                taps, physical, first, last, 0,
                                                volume, address, min, mag, 0,
                                                true, signedHILO);
                                            double lo = hilo16_rect_reference(
                                                x, y, z,
                                                dx * core[0] / physical[0], lod,
                                                taps, physical, first, last, 0,
                                                volume, address, min, mag, 1,
                                                true, signedHILO);
                                            double alpha =
                                                hilo16_rect_reference(
                                                    x, y, z,
                                                    dx * core[0] / physical[0],
                                                    lod, taps, physical, first,
                                                    last, 0, volume, address,
                                                    min, mag, 2, true,
                                                    signedHILO);
                                            double normalZ =
                                                signedHILO ?
                                                    sqrt(
                                                        MAX(0.0, 1 - hi * hi -
                                                                     lo * lo)) :
                                                    1;
                                            double lookupS = .5 * hi +
                                                             .25 * lo +
                                                             .125 * normalZ,
                                                   lookupT = .25 * hi +
                                                             .5 * lo +
                                                             .125 * normalZ;
                                            const double expected[] = {
                                                dependent ?
                                                    (signedHILO ?
                                                         MAX(.0625,
                                                             MIN(.9375,
                                                                 lookupS)) :
                                                         lookupS) :
                                                    (signedHILO ?
                                                         MAX(0.0, hi * 65536 /
                                                                      65535) :
                                                         hi),
                                                dependent ?
                                                    (signedHILO ?
                                                         MAX(.0625,
                                                             MIN(.9375,
                                                                 lookupT)) :
                                                         lookupT) :
                                                    (signedHILO ?
                                                         MAX(0.0, lo * 65536 /
                                                                      65535) :
                                                         lo),
                                                dependent ?
                                                    .2 :
                                                    (signedHILO ?
                                                         MAX(0.0, lo * 65536 /
                                                                      65535) :
                                                         lo),
                                                dependent ? .75 : alpha
                                            };
                                            const float *actual =
                                                (const float
                                                     *)((const uint8_t *)
                                                            out.contents +
                                                        py * 256 + px * 16);
                                            for (unsigned k = 0; k < 4; k++) {
                                                if (!isfinite(actual[k]) ||
                                                    fabs(actual[k] -
                                                         expected[k]) >
                                                        (signedHILO ? .000002 :
                                                                      .00003)) {
                                                    fprintf(
                                                        stderr,
                                                        "HILO physical border "
                                                        "volume%u shape%u "
                                                        "range%u addr%u "
                                                        "profile%u dep%u "
                                                        "pixel%u,%u ch%u:%.9g "
                                                        "expected%.9g\n",
                                                        volume, shape, range,
                                                        address, profile,
                                                        dependent, px, py, k,
                                                        actual[k], expected[k]);
                                                    abort();
                                                }
                                                channels++;
                                            }
                                        }
                                    draws++;
                                    eightTapDraws += taps == 8;
                                }
                            }
                            dma_a.limit--;
                            pg->texture_dirty[0] = true;
                            assert(![adapter prepareWithError:&error] &&
                                   pg->texture_dirty[0]);
                            shortDMA++;
                            dma_a = oldDMA;
                            captures++;
                        }
                    }
    assert(captures == 5920 && draws == 23680 && channels == 1515520 &&
           eightTapDraws == 2960 && shortDMA == 5920 && rawTexels == 357512 &&
           pointFaces[0] == 15 && pointFaces[1] == 63);
    printf("Metal4 %sHILO16 physical border: %u captures/restores/%u draws/%u "
           "full-frame channels/%u raw texels/%u eight-tap draws/%u short-DMA "
           "rejects PASS\n",
           signedHILO ? "signed " : "", captures, draws, channels, rawTexels,
           eightTapDraws, shortDMA);
    if (signedHILO)
        printf("Metal4 signed HILO16 physical border: 5920 exact Stage3 "
               "resaves/357512 bit-exact raw texels PASS\n");
}

static double legacy_cropped_cube_value(unsigned x, unsigned y, unsigned face,
                                        bool hilo, unsigned channel)
{
    x += 4;
    y += 4;
    if (!hilo)
        return ((x + 17 * y + 37 * face) & 255) / 255.0;
    unsigned value = channel == 0 ?
                         (0x1234 + 499 * x + 977 * y + 5003 * face) & 65535 :
                         (0x4567 + 613 * x + 1297 * y + 7001 * face) & 65535;
    return value / 65535.0;
}
static void legacy_cropped_cube_tests(void)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:surfaces.commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:4
                                    height:4
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target =
        [surfaces.commands.device newTextureWithDescriptor:td];
    assert(target);
    const double positions[][2] = { { .25, .25 },   { .75, .25 },
                                    { .25, .75 },   { .75, .75 },
                                    { .5, .5 },     { .125, .125 },
                                    { .875, .875 }, { .3125, .6875 } };
    unsigned loads = 0, rawTexels = 0, draws = 0, channels = 0, canonical = 0,
             versions = 0;
    for (unsigned capture = 0;
         capture < ARRAY_SIZE(legacy_cropped_cube_captures); capture++) {
        bool hilo = capture >= 4;
        unsigned stage = capture % 4 >= 2 ? 3 : 0;
        bool linear = capture % 2;
        uint8_t bytes[sizeof(legacy_cropped_cube_captures[0])];
        for (unsigned i = 0; i < ARRAY_SIZE(legacy_cropped_cube_captures[0]);
             i++)
            stl_be_p(bytes + 4 * i, legacy_cropped_cube_captures[capture][i]);
        NSData *fixture = [NSData dataWithBytes:bytes length:sizeof(bytes)];
        for (unsigned version = hilo ? 3 : 1; version <= 3; version++) {
            NSData *wire = fixture;
            if (version == 1)
                wire = legacy_stage_fixture(fixture);
            if (version == 2) {
                NSMutableData *v2 = [fixture mutableCopy];
                stl_be_p((uint8_t *)v2.mutableBytes + 4, 2);
                wire = v2;
            }
            require([NV2AMetalPGRAPHTextureSnapshot validateSnapshot:wire
                                                               error:&error],
                    error);
            NV2AMetalPGRAPHTextureSnapshot *restored =
                [[NV2AMetalPGRAPHTextureSnapshot alloc]
                    initWithSnapshot:wire
                            commands:surfaces.commands
                               error:&error];
            require(restored != nil, error);
            NV2AMetalPixelUniforms frozen = {};
            NV2AMetalPixelTexture bindings[4] = {};
            require([restored applyToUniforms:&frozen
                                     textures:bindings
                                        error:&error],
                    error);
            id<MTLTexture> texture = bindings[stage].texture;
            assert(restored.enabledMask == (1u << stage) &&
                   frozen.hilo16_mask == (hilo ? 1u << stage : 0));
            assert(texture.textureType == MTLTextureTypeCube &&
                   texture.width == 2 && texture.height == 2 &&
                   texture.depth == 1 && texture.mipmapLevelCount == 1);
            for (unsigned axis = 0; axis < 3; axis++) {
                assert(frozen.textures[stage].border_logical_size[axis] == 0);
                assert(frozen.textures[stage].border_inv_real_size[axis] == 0);
            }
            assert(frozen.textures[stage].sampling.enabled &&
                   frozen.textures[stage].sampling.mag_linear == linear);
            for (unsigned face = 0; face < 6; face++) {
                id<MTLBuffer> raw = read_subresource(texture, 0, face);
                finish();
                for (unsigned y = 0; y < 2; y++)
                    for (unsigned x = 0; x < 2; x++) {
                        const float *actual =
                            (const float *)((const uint8_t *)raw.contents +
                                            y * 256 + x * 16);
                        for (unsigned k = 0; k < 4; k++) {
                            double want = k == 3 ? 1 :
                                                   legacy_cropped_cube_value(
                                                       x, y, face, hilo, k);
                            assert(isfinite(actual[k]) &&
                                   fabs(actual[k] - want) < .000001);
                        }
                        rawTexels++;
                    }
                for (unsigned profile = 0; profile < ARRAY_SIZE(positions);
                     profile++) {
                    double u = positions[profile][0], v = positions[profile][1];
                    double a = 2 * u - 1, b = 2 * v - 1;
                    const double directions[][3] = {
                        { 1, -b, -a }, { -1, -b, a }, { a, 1, b },
                        { a, -1, -b }, { a, -b, 1 },  { -a, -b, -1 }
                    };
                    NV2AMetalPixelUniforms uniforms = frozen;
                    uniforms.combiner.shader_stage_program =
                        PS_TEXTUREMODES_CUBEMAP << (5 * stage);
                    uniforms.surface_scale[0] = uniforms.surface_scale[1] = 1;
                    uniforms.smooth_shading = 1;
                    uniforms.clip_range[1] = uniforms.clip_range[3] = 65535;
                    uniforms.clip_regions[0][2] = uniforms.clip_regions[0][3] =
                        4;
                    uniforms.combiner.final_inputs[0] = PS_REGISTER_T0 + stage;
                    uniforms.combiner.final_inputs[1] =
                        (PS_REGISTER_T0 + stage | PS_CHANNEL_ALPHA) << 8;
                    NV2AMetalVertex vertices[6] = {};
                    const float xy[][2] = { { -1, 1 }, { 1, 1 },  { -1, -1 },
                                            { 1, 1 },  { 1, -1 }, { -1, -1 } };
                    for (unsigned j = 0; j < 6; j++) {
                        vertices[j].clip[0] = xy[j][0];
                        vertices[j].clip[1] = xy[j][1];
                        vertices[j].clip[2] = .5f;
                        vertices[j].clip[3] = 1;
                        const float plane[3][4] = { { 0, 0, .5f, 1 },
                                                    { 4, 0, .5f, 1 },
                                                    { 0, 4, .5f, 1 } };
                        memcpy(vertices[j].plane, plane, sizeof(plane));
                        for (unsigned k = 0; k < 3; k++)
                            vertices[j].texcoord[stage][k] =
                                directions[face][k];
                        vertices[j].texcoord[stage][3] = 1;
                    }
                    id<MTLBuffer> out = hilo16_volume_draw(
                        shader, target, &uniforms, bindings, vertices);
                    double x = u * 2 - (linear ? .5 : 0),
                           y = v * 2 - (linear ? .5 : 0);
                    int bx = floor(x), by = floor(y);
                    double fx = x - bx, fy = y - by,
                           expected[4] = { 0, 0, 0, 1 };
                    for (unsigned corner = 0; corner < (linear ? 4u : 1u);
                         corner++) {
                        unsigned highX = corner & 1, highY = corner >> 1;
                        double weight = linear ? (highX ? fx : 1 - fx) *
                                                     (highY ? fy : 1 - fy) :
                                                 1;
                        unsigned sx = MAX(0, MIN(1, bx + (int)highX)),
                                 sy = MAX(0, MIN(1, by + (int)highY));
                        for (unsigned k = 0; k < 3; k++)
                            expected[k] += weight * legacy_cropped_cube_value(
                                                        sx, sy, face, hilo, k);
                    }
                    for (unsigned py = 0; py < 4; py++)
                        for (unsigned px = 0; px < 4; px++) {
                            const float *actual =
                                (const float *)((const uint8_t *)out.contents +
                                                py * 256 + px * 16);
                            for (unsigned k = 0; k < 4; k++) {
                                if (!isfinite(actual[k]) ||
                                    fabs(actual[k] - expected[k]) > .00003) {
                                    fprintf(
                                        stderr,
                                        "Legacy cropped cube capture%u "
                                        "version%u face%u profile%u pixel%u,%u "
                                        "ch%u:%.9g expected%.9g\n",
                                        capture, version, face, profile, px, py,
                                        k, actual[k], expected[k]);
                                    abort();
                                }
                                channels++;
                            }
                        }
                    draws++;
                }
            }
            NSData *resaved = [restored snapshotWithCommands:surfaces.commands
                                                       error:&error];
            require(resaved != nil, error);
            assert([resaved isEqualToData:fixture]);
            canonical++;
            loads++;
            versions |= 1u << version;
        }
    }
    assert(loads == 16 && rawTexels == 384 && draws == 768 &&
           channels == 49152 && canonical == 16 && versions == 14);
    printf("Metal4 legacy cropped cubes: eight historical captures/three stage "
           "versions/%u restores/%u raw texels/%u draws/%u full-frame "
           "channels/%u exact canonical resaves PASS\n",
           loads, rawTexels, draws, channels, canonical);
    checks++;
}

static void cube_border_direction(unsigned face, double s, double t,
                                  double scale, bool project, double out[3])
{
    double u = 2 * s - 1, v = 2 * t - 1;
    const double directions[][3] = { { 1, -v, -u }, { -1, -v, u },
                                     { u, 1, v },   { u, -1, -v },
                                     { u, -v, 1 },  { -u, -v, -1 } };
    double length = project ? sqrt(directions[face][0] * directions[face][0] +
                                   directions[face][1] * directions[face][1] +
                                   directions[face][2] * directions[face][2]) :
                              1 / scale;
    for (unsigned k = 0; k < 3; k++)
        out[k] = directions[face][k] / length;
}
static unsigned
cube_border_reference(unsigned inputFace, double s, double t, double dx,
                      double dy, unsigned px, unsigned py, double scale,
                      bool project, unsigned core, unsigned first,
                      unsigned last, unsigned address, unsigned min,
                      unsigned mag, unsigned anisotropy, double bias,
                      double out[4], unsigned *selectedFace, BOOL signedHILO)
{
    double c[3], left[3], right[3], top[3], bottom[3], gx[3], gy[3];
    cube_border_direction(inputFace, s, t, scale, project, c);
    cube_border_direction(inputFace, s - (px & 1) * dx, t, scale, project,
                          left);
    cube_border_direction(inputFace, s + (1 - (px & 1)) * dx, t, scale, project,
                          right);
    cube_border_direction(inputFace, s, t - (py & 1) * dy, scale, project, top);
    cube_border_direction(inputFace, s, t + (1 - (py & 1)) * dy, scale, project,
                          bottom);
    for (unsigned k = 0; k < 3; k++) {
        gx[k] = right[k] - left[k];
        gy[k] = bottom[k] - top[k];
    }
    unsigned axis = 0;
    for (unsigned k = 1; k < 3; k++)
        if (fabs(c[k]) > fabs(c[axis]))
            axis = k;
    unsigned face = 2 * axis + (c[axis] < 0);
    *selectedFace = face;
    const int basis[6][3][3] = { { { 0, 0, -1 }, { 0, -1, 0 }, { 1, 0, 0 } },
                                 { { 0, 0, 1 }, { 0, -1, 0 }, { -1, 0, 0 } },
                                 { { 1, 0, 0 }, { 0, 0, 1 }, { 0, 1, 0 } },
                                 { { 1, 0, 0 }, { 0, 0, -1 }, { 0, -1, 0 } },
                                 { { 1, 0, 0 }, { 0, -1, 0 }, { 0, 0, 1 } },
                                 { { -1, 0, 0 }, { 0, -1, 0 }, { 0, 0, -1 } } };
    double projected[3] = {}, ddx[3] = {}, ddy[3] = {};
    for (unsigned i = 0; i < 3; i++)
        for (unsigned k = 0; k < 3; k++) {
            projected[i] += basis[face][i][k] * c[k];
            ddx[i] += basis[face][i][k] * gx[k];
            ddy[i] += basis[face][i][k] * gy[k];
        }
    unsigned physical = MAX(16u, 2 * core);
    double uv[2], ux[2], uy[2], m = projected[2];
    for (unsigned i = 0; i < 2; i++) {
        uv[i] = (.5 * (projected[i] / m + 1) * core + 4) / physical;
        ux[i] = .5 * (ddx[i] * m - projected[i] * ddx[2]) / (m * m) * core /
                physical;
        uy[i] = .5 * (ddy[i] * m - projected[i] * ddy[2]) / (m * m) * core /
                physical;
    }
    double x = hypot(ux[0], ux[1]) * (physical >> first),
           y = hypot(uy[0], uy[1]) * (physical >> first);
    double major = MAX(x, y), minor = MIN(x, y);
    unsigned taps =
        anisotropy > 1 && major > 1 ?
            MIN(anisotropy,
                MAX(1u, (unsigned)ceil(major / MAX(minor, 1e-30)))) :
            1;
    double lod = log2(MAX(major / taps, 1e-30)) + bias;
    bool linear = lod <= 0 ? mag == 2 : min % 2 == 0;
    double l = min < 3 ? 0 : MAX(0, MIN((double)(last - first), lod));
    unsigned low = 0, high = 0;
    double blend = 0;
    if (min >= 5) {
        low = floor(l);
        high = MIN(low + 1, last - first);
        blend = l - low;
    } else if (min >= 3) {
        for (unsigned i = 1; i <= last - first; i++)
            if (fabs(l - i) < fabs(l - low))
                low = i;
        high = low;
    }
    for (unsigned k = 0; k < 4; k++)
        out[k] = 0;
    for (unsigned tap = 0; tap < taps; tap++) {
        double offset = ((double)tap + 1) / (taps + 1) - .5;
        double u = uv[0] + (x > y ? ux[0] : uy[0]) * offset,
               v = uv[1] + (x > y ? ux[1] : uy[1]) * offset;
        for (unsigned channel = 0; channel < 3; channel++) {
            double a = hilo16_volume_level(u, v, .5, physical, first + low,
                                           face, false, address, linear,
                                           channel, true, signedHILO);
            double b = hilo16_volume_level(u, v, .5, physical, first + high,
                                           face, false, address, linear,
                                           channel, true, signedHILO);
            double value = (a * (1 - blend) + b * blend) / taps;
            if (channel == 0)
                out[0] += value;
            else if (channel == 1) {
                out[1] += value;
                out[2] += value;
            } else
                out[3] += value;
        }
    }
    return taps;
}
static void hilo16_cube_border_tests(BOOL signedHILO)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:surfaces.commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(shader != nil, error);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:4
                                    height:4
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target =
        [surfaces.commands.device newTextureWithDescriptor:td];
    td.width = td.height = 8;
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> lookup =
        [surfaces.commands.device newTextureWithDescriptor:td];
    assert(target && lookup);
    float gradient[8][8][4];
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            const float pixel[] = { (x + .5f) / 8, (y + .5f) / 8, .2f, .75f };
            memcpy(gradient[y][x], pixel, sizeof(pixel));
        }
    [lookup replaceRegion:MTLRegionMake2D(0, 0, 8, 8)
              mipmapLevel:0
                withBytes:gradient
              bytesPerRow:sizeof(gradient[0])];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> sampler =
        [surfaces.commands.device newSamplerStateWithDescriptor:sd];
    assert(sampler);


    unsigned captures = 0, draws = 0, channels = 0, rawTexels = 0, shortDMA = 0;
    unsigned tapPixels[9] = {}, faceMask = 0, changedFacePixels = 0,
             modeDraws[3] = {};
    DMAObject oldDMA = dma_a;
    for (unsigned log = 0; log <= 4; log++)
        for (unsigned range = 0; range < (log ? 3u : 1u); range++)
            for (unsigned address = 3; address <= 4; address++)
                for (unsigned profile = 0; profile < 10; profile++) {
                    @autoreleasepool {
                        unsigned core = 1u << log,
                                 physical = MAX(16u, 2 * core);
                        unsigned first = range == 0 ? 0 :
                                         range == 1 ? 1 :
                                                      log,
                                 last = log;
                        unsigned min = profile < 2  ? 1 :
                                       profile < 4  ? 2 :
                                       profile < 8  ? profile - 1 :
                                       profile == 8 ? 6 :
                                                      5;
                        unsigned mag = min % 2 == 0 ? 2 : 1,
                                 anisotropy = profile == 8 ? 4 :
                                              profile == 9 ? 8 :
                                                             1;
                        double centerS = profile == 1 || profile == 2 ?
                                             .015625 :
                                         profile == 3 ? .984375 :
                                                        .53125;
                        double centerT = profile == 1 ? .984375 :
                                         profile == 2 ? .03125 :
                                         profile == 3 ? .96875 :
                                                        .46875;
                        double dx = profile < 4 ? 0 :
                                    profile < 8 ? 1.0 / 256 :
                                                  2.0 / (core >> first);
                        double dy = profile < 8 ? dx * .75 : dx / anisotropy;
                        int bias =
                            profile < 4  ? 0 :
                            profile < 8  ? (8 - (log - first)) * 256 + 192 :
                            profile == 8 ? 448 :
                                           704;
                        PGRAPHState *pg = &state->pgraph;
                        for (unsigned i = 0; i < 4; i++)
                            pg->regs_[NV_PGRAPH_TEXCTL0_0 + 4 * i] = 0;
                        registers(0,
                                  NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16,
                                  core, 0, 4096, false);
                        uint32_t *fmt = &pg->regs_[NV_PGRAPH_TEXFMT0];
                        *fmt &= ~NV_PGRAPH_TEXFMT0_BORDER_SOURCE;
                        *fmt |= NV_PGRAPH_TEXFMT0_CUBEMAPENABLE;
                        SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_BASE_SIZE_U, log);
                        SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_BASE_SIZE_V, log);
                        SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_BASE_SIZE_P, 0);
                        SET_MASK(*fmt, NV_PGRAPH_TEXFMT0_MIPMAP_LEVELS,
                                 log + 1);
                        uint32_t *ctl = &pg->regs_[NV_PGRAPH_TEXCTL0_0];
                        SET_MASK(*ctl, NV_PGRAPH_TEXCTL0_0_MIN_LOD_CLAMP,
                                 first);
                        SET_MASK(*ctl, NV_PGRAPH_TEXCTL0_0_MAX_LOD_CLAMP, last);
                        SET_MASK(*ctl, NV_PGRAPH_TEXCTL0_0_MAX_ANISOTROPY,
                                 anisotropy == 8 ? 3 :
                                 anisotropy == 4 ? 2 :
                                                   0);
                        pg->regs_[NV_PGRAPH_TEXFILTER0] =
                            min << 16 | mag << 24 | bias |
                            (signedHILO ? 0xf0000000u : 0);
                        pg->regs_[NV_PGRAPH_TEXADDRESS0] =
                            address | address << 8 | 3 << 16;
                        pg->regs_[NV_PGRAPH_BORDERCOLOR0] = 0xff128989;
                        pg->regs_[NV_PGRAPH_SHADERPROG] =
                            PS_TEXTUREMODES_CUBEMAP;
                        unsigned faceLength = 0;
                        for (unsigned level = 0; level <= last; level++) {
                            unsigned size = physical >> level;
                            faceLength += size * size * 4;
                        }
                        unsigned stride = (faceLength + 127) & ~127u,
                                 length = stride * 6;
                        cpu_write(8192, length);
                        memset(state->vram_ptr + 8192, 0xd3, length);
                        for (unsigned face = 0; face < 6; face++) {
                            unsigned offset = face * stride;
                            for (unsigned level = 0; level <= last; level++) {
                                unsigned size = physical >> level;
                                for (unsigned y = 0; y < size; y++)
                                    for (unsigned x = 0; x < size; x++)
                                        stl_le_p(
                                            state->vram_ptr + 8192 + offset +
                                                4 * volume_mip_morton(
                                                        x, y, 0, size, size, 1),
                                            hilo16_volume_word(x, y, 0, face,
                                                               level));
                                offset += size * size * 4;
                            }
                        }
                        dma_a.limit = 4096 + length - 1;
                        NV2AMetalPGRAPHTextureSnapshot *original = prepare();
                        finish();
                        NSData *wire =
                            [original snapshotWithCommands:surfaces.commands
                                                     error:&error];
                        require(wire != nil, error);
                        NV2AMetalPGRAPHTextureSnapshot *restored =
                            [[NV2AMetalPGRAPHTextureSnapshot alloc]
                                initWithSnapshot:wire
                                        commands:surfaces.commands
                                           error:&error];
                        require(restored != nil, error);
                        if (signedHILO) {
                            NSData *again =
                                [restored snapshotWithCommands:surfaces.commands
                                                         error:&error];
                            require(again != nil, error);
                            assert([again isEqualToData:wire]);
                        }

                        cpu_write(8192, length);
                        memset(state->vram_ptr + 8192, 0x5b, length);
                        for (NV2AMetalPGRAPHTextureSnapshot *snapshot in
                             @[ original, restored ]) {
                            NV2AMetalPixelUniforms frozen = {};
                            NV2AMetalPixelTexture captured[4] = {};
                            require([snapshot applyToUniforms:&frozen
                                                     textures:captured
                                                        error:&error],
                                    error);
                            id<MTLTexture> texture = captured[0].texture;
                            assert(frozen.hilo16_mask == 1 &&
                                   frozen.textures[0].signed_channels ==
                                       (signedHILO ? 15u : 0u) &&
                                   frozen.textures[0].cubemap &&
                                   frozen.textures[0].border_logical_size[0] ==
                                       core &&
                                   frozen.textures[0].border_inv_real_size[0] ==
                                       1.f / physical &&
                                   texture.textureType == MTLTextureTypeCube &&
                                   texture.width == physical >> first &&
                                   texture.mipmapLevelCount ==
                                       last - first + 1);
                            if (address == 3 && profile == 0)
                                for (unsigned face = 0; face < 6; face++)
                                    for (unsigned level = first; level <= last;
                                         level++) {
                                        unsigned size = physical >> level;
                                        id<MTLBuffer> raw = read_subresource(
                                            texture, level - first, face);
                                        finish();
                                        NSUInteger row =
                                            (size * 16 + 255) & ~255u;
                                        for (unsigned y = 0; y < size; y++)
                                            for (unsigned x = 0; x < size;
                                                 x++) {
                                                uint32_t word =
                                                    hilo16_volume_word(
                                                        x, y, 0, face, level);
                                                const float *actual =
                                                    (const float
                                                         *)((const uint8_t *)
                                                                raw.contents +
                                                            y * row + x * 16);
                                                const float expected[] = {
                                                    hilo16_word_component(
                                                        word, 0, signedHILO),
                                                    hilo16_word_component(
                                                        word, 1, signedHILO),
                                                    hilo16_word_component(
                                                        word, 1, signedHILO),
                                                    1
                                                };
                                                if (signedHILO)
                                                    assert(!memcmp(
                                                        actual, expected,
                                                        sizeof(expected)));
                                                for (unsigned k = 0; k < 4; k++)
                                                    assert(
                                                        isfinite(actual[k]) &&
                                                        fabs(actual[k] -
                                                             expected[k]) <
                                                            .000001);
                                                rawTexels++;
                                            }
                                    }
                            for (unsigned mode = 0; mode < 3; mode++)
                                for (unsigned face = 0;
                                     face < (mode == 1 ? 1u : 6u); face++)
                                    for (unsigned dependent = 0;
                                         dependent < (mode == 2 ? 1u : 2u);
                                         dependent++) {
                                        NV2AMetalPixelUniforms u = frozen;
                                        NV2AMetalPixelTexture bindings[4] = {
                                            captured[0]
                                        };
                                        u.surface_scale[0] =
                                            u.surface_scale[1] = 1;
                                        u.smooth_shading = 1;
                                        u.clip_range[1] = u.clip_range[3] =
                                            65535;
                                        u.clip_regions[0][2] =
                                            u.clip_regions[0][3] = 4;
                                        u.combiner.shader_stage_program =
                                            mode == 1 ?
                                                PS_TEXTUREMODES_PROJECT2D :
                                                PS_TEXTUREMODES_CUBEMAP;
                                        u.combiner.final_inputs[0] =
                                            PS_REGISTER_T0;
                                        u.combiner.final_inputs[1] =
                                            (PS_REGISTER_T0 | PS_CHANNEL_ALPHA)
                                            << 8;
                                        if (mode == 2) {
                                            u.textures[3] = u.textures[0];
                                            memset(&u.textures[0], 0,
                                                   sizeof(u.textures[0]));
                                            u.hilo16_mask = 8;
                                            bindings[3] = bindings[0];
                                            bindings[0] =
                                                (NV2AMetalPixelTexture){};
                                            u.combiner.shader_stage_program =
                                                PS_TEXTUREMODES_PASSTHRU |
                                                PS_TEXTUREMODES_DOTPRODUCT
                                                    << 5 |
                                                PS_TEXTUREMODES_DOTPRODUCT
                                                    << 10 |
                                                PS_TEXTUREMODES_DOT_STR_CUBE
                                                    << 15;
                                            u.combiner.final_inputs[0] =
                                                PS_REGISTER_T3;
                                            u.combiner.final_inputs[1] =
                                                (PS_REGISTER_T3 |
                                                 PS_CHANNEL_ALPHA)
                                                << 8;
                                        } else if (dependent) {
                                            u.combiner.shader_stage_program |=
                                                PS_TEXTUREMODES_DOTPRODUCT
                                                    << 5 |
                                                PS_TEXTUREMODES_DOT_ST << 10;
                                            unsigned mapping =
                                                (face + profile) % 8;
                                            u.other_stage_input =
                                                mapping | mapping << 4;
                                            u.textures[1].dimension =
                                                u.textures[2].dimension = 2;
                                            u.textures[2].scale = 1;
                                            u.textures[2].sampling.enabled = 1;
                                            u.textures[2].sampling.min_linear =
                                                u.textures[2]
                                                    .sampling.mag_linear = 1;
                                            u.textures[2].sampling.anisotropy =
                                                1;
                                            for (unsigned k = 0; k < 3; k++)
                                                u.textures[2]
                                                    .sampling.address[k] = 3;
                                            bindings[2].texture = lookup;
                                            bindings[2].sampler = sampler;
                                            u.combiner.final_inputs[0] =
                                                PS_REGISTER_T2;
                                            u.combiner.final_inputs[1] =
                                                (PS_REGISTER_T2 |
                                                 PS_CHANNEL_ALPHA)
                                                << 8;
                                        }
                                        NV2AMetalVertex vertices[6] = {};
                                        const float xy[][2] = {
                                            { -1, 1 }, { 1, 1 },  { -1, -1 },
                                            { 1, 1 },  { 1, -1 }, { -1, -1 }
                                        };
                                        double scale = ldexp(
                                            1.0,
                                            (int)((face + profile) % 4) - 2);
                                        for (unsigned j = 0; j < 6; j++) {
                                            vertices[j].clip[0] = xy[j][0];
                                            vertices[j].clip[1] = xy[j][1];
                                            vertices[j].clip[2] = .5f;
                                            vertices[j].clip[3] = 1;
                                            const float plane[3][4] = {
                                                { 0, 0, .5f, 1 },
                                                { 4, 0, .5f, 1 },
                                                { 0, 4, .5f, 1 }
                                            };
                                            memcpy(vertices[j].plane, plane,
                                                   sizeof(plane));
                                            double direction[3];
                                            cube_border_direction(
                                                face,
                                                centerS + xy[j][0] * 2 * dx,
                                                centerT - xy[j][1] * 2 * dy,
                                                scale, false, direction);
                                            if (mode == 2) {
                                                vertices[j].texcoord[0][0] = 1;
                                                vertices[j].texcoord[0][3] = 1;
                                                for (unsigned k = 0; k < 3;
                                                     k++) {
                                                    vertices[j]
                                                        .texcoord[k + 1][0] =
                                                        direction[k];
                                                    vertices[j]
                                                        .texcoord[k + 1][3] = 1;
                                                }
                                            } else {
                                                for (unsigned k = 0; k < 3; k++)
                                                    vertices[j].texcoord[0][k] =
                                                        direction[k];
                                                if (mode == 1) {
                                                    vertices[j].texcoord[0][0] =
                                                        -direction[2] /
                                                        direction[0];
                                                    vertices[j].texcoord[0][1] =
                                                        direction[1] /
                                                        direction[0];
                                                }
                                                vertices[j].texcoord[0][3] = 1;
                                                const float dotS[] = { .5f,
                                                                       .25f,
                                                                       .125f,
                                                                       1 },
                                                            dotT[] = { .25f,
                                                                       .5f,
                                                                       .125f,
                                                                       1 };
                                                memcpy(vertices[j].texcoord[1],
                                                       dotS, sizeof(dotS));
                                                memcpy(vertices[j].texcoord[2],
                                                       dotT, sizeof(dotT));
                                            }
                                        }
                                        id<MTLBuffer> out = hilo16_volume_draw(
                                            shader, target, &u, bindings,
                                            vertices);
                                        for (unsigned py = 0; py < 4; py++)
                                            for (unsigned px = 0; px < 4;
                                                 px++) {
                                                double expected[4];
                                                unsigned actualFace;
                                                unsigned taps =
                                                    cube_border_reference(
                                                        face,
                                                        centerS +
                                                            (px + .5 - 2) * dx,
                                                        centerT +
                                                            (py + .5 - 2) * dy,
                                                        dx, dy, px, py, scale,
                                                        mode == 1, core, first,
                                                        last, address, min, mag,
                                                        anisotropy,
                                                        bias / 256.0, expected,
                                                        &actualFace,
                                                        signedHILO);
                                                tapPixels[taps]++;
                                                faceMask |= 1u << actualFace;
                                                changedFacePixels +=
                                                    actualFace != face;
                                                if (dependent) {
                                                    double hi = expected[0],
                                                           lo = expected[1];
                                                    double normalZ =
                                                        signedHILO ?
                                                            sqrt(MAX(
                                                                0.0,
                                                                1 - hi * hi -
                                                                    lo * lo)) :
                                                            1;
                                                    expected[0] =
                                                        .5 * hi + .25 * lo +
                                                        .125 * normalZ;
                                                    expected[1] =
                                                        .25 * hi + .5 * lo +
                                                        .125 * normalZ;
                                                    if (signedHILO) {
                                                        expected[0] = MAX(
                                                            .0625,
                                                            MIN(.9375,
                                                                expected[0]));
                                                        expected[1] = MAX(
                                                            .0625,
                                                            MIN(.9375,
                                                                expected[1]));
                                                    }
                                                    expected[2] = .2;
                                                    expected[3] = .75;
                                                } else if (signedHILO) {
                                                    for (unsigned k = 0; k < 3;
                                                         k++)
                                                        expected[k] = MAX(
                                                            0.0, expected[k] *
                                                                     65536 /
                                                                     65535);
                                                }
                                                const float *actual =
                                                    (const float
                                                         *)((const uint8_t *)
                                                                out.contents +
                                                            py * 256 + px * 16);
                                                for (unsigned k = 0; k < 4;
                                                     k++) {
                                                    if (!isfinite(actual[k]) ||
                                                        fabs(actual[k] -
                                                             expected[k]) >
                                                            (signedHILO ?
                                                                 .000002 :
                                                                 .00005)) {
                                                        fprintf(
                                                            stderr,
                                                            "Cube border "
                                                            "core%u range%u "
                                                            "addr%u profile%u "
                                                            "mode%u face%u "
                                                            "dep%u px%u,%u "
                                                            "ch%u taps%u:%.9g "
                                                            "expected%.9g\n",
                                                            core, range,
                                                            address, profile,
                                                            mode, face,
                                                            dependent, px, py,
                                                            k, taps, actual[k],
                                                            expected[k]);
                                                        abort();
                                                    }
                                                    channels++;
                                                }
                                            }
                                        draws++;
                                        modeDraws[mode]++;
                                    }
                        }
                        dma_a.limit--;
                        pg->texture_dirty[0] = true;
                        assert(![adapter prepareWithError:&error] &&
                               pg->texture_dirty[0]);
                        shortDMA++;
                        dma_a = oldDMA;
                        captures++;
                    }
                }
    assert(captures == 260 && draws == 10400 && channels == 665600 &&
           rawTexels == 39264 && shortDMA == 260 && faceMask == 63 &&
           tapPixels[8] > 0 && changedFacePixels > 0);
    printf("Metal4 %sphysical cube border: %u captures/restores/%u draws/%u "
           "full-frame channels/%u raw texels/%u shortDMA rejects; "
           "modes%u/%u/%u, eightTapPixels%u, changedFacePixels%u PASS\n",
           signedHILO ? "signed " : "", captures, draws, channels, rawTexels,
           shortDMA, modeDraws[0], modeDraws[1], modeDraws[2], tapPixels[8],
           changedFacePixels);
    if (signedHILO)
        printf("Metal4 signed HILO16 cube border: 260 exact Stage3 "
               "resaves/39264 bit-exact raw texels PASS\n");
}

static void palette_tests(void)
{
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    registers(0, NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8, 4, 0, 4096,
              false);
    pg->regs_[NV_PGRAPH_TEXPALETTE0] =
        512 | NV_PGRAPH_TEXPALETTE0_CONTEXT_DMA | 3 << 2;
    cpu_write(dma_a.address + 4096, 16);
    memset(state->vram_ptr + dma_a.address + 4096, 0, 16);
    cpu_write(dma_b.address + 512, 128);
    uint32_t word = 0xff112233;
    memcpy(state->vram_ptr + dma_b.address + 512, &word, 4);
    NV2AMetalPGRAPHTextureSnapshot *s = prepare();
    assert(!surfaces.commands.commandBuffer);
    require([s validateCompletedWithError:&error], error);
    stage_roundtrip(s);
    id<MTLBuffer> out = read_texture(s, 0);
    finish();
    pixel(out, 4, 0, 0, 0x11 / 255.f, 0x22 / 255.f, 0x33 / 255.f, 1);
    cpu_write(dma_a.address + 4096, 16);
    memset(state->vram_ptr + dma_a.address + 4096, 32, 16);
    pg->texture_dirty[0] = true;
    assert(![adapter prepareWithError:&error] &&
           !surfaces.commands.commandBuffer);
    assert(pg->texture_dirty[0]);
    checks++;
}
static void palette_completion_tests(void)
{
    NSError *error = nil;
    TextureTestSurfaces *counted = (TextureTestSurfaces *)surfaces;
    PGRAPHState *pg = &state->pgraph;
    only_stage0();
    registers(0, NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8,
              4, 0, 4096, false);
    pg->regs_[NV_PGRAPH_TEXPALETTE0] =
        512 | NV_PGRAPH_TEXPALETTE0_CONTEXT_DMA | 3 << 2;
    NSUInteger indices = dma_a.address + 4096;
    NSUInteger palette = dma_b.address + 512;
    cpu_write(indices, 16);
    memset(state->vram_ptr + indices, 0, 16);
    cpu_write(palette, 128);
    memset(state->vram_ptr + palette, 0, 128);
    uint32_t words[] = { 0xff112233, 0xffaa3355 };
    memcpy(state->vram_ptr + palette, words, sizeof(words));
    NSUInteger waits = counted.waits;
    NV2AMetalPGRAPHTextureSnapshot *first = prepare();
    assert(counted.waits == waits + 1);
    require([first validateCompletedWithError:&error], error);
    id<MTLBuffer> oldPixels = read_texture(first, 0);
    id<MTL4CommandBuffer> pending = surfaces.commands.commandBuffer;
    waits = counted.waits;
    NSUInteger submissions = counted.submissions;
    for (unsigned i = 0; i < 8; i++) {
        /* A new sampling binding must retain completed content validation. */
        pg->regs_[NV_PGRAPH_BORDERCOLOR0] = i;
        NV2AMetalPGRAPHTextureSnapshot *hit = prepare();
        assert([hit textureAtIndex:0].binding.texture ==
               [first textureAtIndex:0].binding.texture);
        if (counted.waits != waits || counted.submissions != submissions) {
            fprintf(stderr, "Completed palette cache hit forced a submission/wait\n");
            abort();
        }
        assert(surfaces.commands.commandBuffer == pending);
    }
    /* Submit the retained old texture's consumer without a CPU wait, then
     * replace palette content while that work may still be in flight. */
    require([surfaces submitWithError:&error], error);
    cpu_write(palette, 4);
    words[0] = 0xff334477;
    memcpy(state->vram_ptr + palette, words, 4);
    waits = counted.waits;
    NV2AMetalPGRAPHTextureSnapshot *changed = prepare();
    assert(counted.waits == waits + 1);
    pixel(oldPixels, 4, 0, 0, 0x11 / 255.f, 0x22 / 255.f, 0x33 / 255.f, 1);
    assert([changed textureAtIndex:0].binding.texture !=
           [first textureAtIndex:0].binding.texture);
    id<MTLBuffer> pixels = read_texture(changed, 0);
    id<MTLBuffer> retained = read_texture(first, 0);
    finish();
    pixel(pixels, 4, 0, 0, 0x33 / 255.f, 0x44 / 255.f, 0x77 / 255.f, 1);
    pixel(retained, 4, 0, 0, 0x11 / 255.f, 0x22 / 255.f, 0x33 / 255.f, 1);

    cpu_write(indices, 16);
    memset(state->vram_ptr + indices, 1, 16);
    waits = counted.waits;
    changed = prepare();
    assert(counted.waits == waits + 1);
    pixels = read_texture(changed, 0);
    finish();
    pixel(pixels, 4, 0, 0, 0xaa / 255.f, 0x33 / 255.f, 0x55 / 255.f, 1);

    cpu_write(indices, 16);
    memset(state->vram_ptr + indices, 32, 16);
    pg->texture_dirty[0] = true;
    waits = counted.waits;
    assert(![adapter prepareWithError:&error] && error);
    assert(counted.waits == waits + 1 && pg->texture_dirty[0]);
    waits = counted.waits;
    error = nil;
    assert(![adapter prepareWithError:&error] && error);
    assert(counted.waits == waits && pg->texture_dirty[0]);

    cpu_write(indices, 16);
    memset(state->vram_ptr + indices, 0, 16);
    counted.failNextWait = YES;
    waits = counted.waits;
    error = nil;
    assert(![adapter prepareWithError:&error]);
    assert([error.domain isEqualToString:@"test.texture.completion"]);
    assert(counted.waits == waits + 1 && pg->texture_dirty[0]);
    waits = counted.waits;
    changed = prepare();
    assert(counted.waits == waits + 1);
    require([changed validateCompletedWithError:&error], error);
    finish();

    cpu_write(indices, 16);
    memset(state->vram_ptr + indices, 1, 16);
    pg->texture_dirty[0] = true;
    counted.cancelNextSubmit = YES;
    error = nil;
    assert(![adapter prepareWithError:&error]);
    assert([error.domain isEqualToString:@"test.texture.cancelled"]);
    assert(pg->texture_dirty[0]);
    waits = counted.waits;
    changed = prepare();
    assert(counted.waits == waits + 1);
    require([changed validateCompletedWithError:&error], error);
    pixels = read_texture(changed, 0);
    finish();
    pixel(pixels, 4, 0, 0, 0xaa / 255.f, 0x33 / 255.f, 0x55 / 255.f, 1);

    /* A completed palette hit does not force a different, non-paletted
     * stage's pending decode to complete. That stage is ordered on the GPU. */
    NSUInteger mixedAddress = dma_a.address + 32768;
    assert(mixedAddress / 4096 != indices / 4096 &&
           mixedAddress / 4096 != palette / 4096);
    registers(1, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8, 4, 4, 32768, false);
    cpu_write(mixedAddress, 16);
    memset(state->vram_ptr + mixedAddress, 99, 16);
    waits = counted.waits;
    NV2AMetalPGRAPHTextureSnapshot *mixed = prepare();
    assert(counted.waits == waits && surfaces.commands.commandBuffer);
    assert(![mixed validateCompletedWithError:&error]);
    finish();
    require([mixed validateCompletedWithError:&error], error);
    only_stage0();
    stage_roundtrip(changed);
    puts("PGRAPH palette completion: initial/changed uploads validate; eight "
         "completed hits add zero submissions/waits; invalid indices, injected "
         "completion failure and cancellation/retry, queued old pixels, "
         "mixed pending stage and "
         "snapshot roundtrip PASS");
    checks++;
}
static void tcg_external_surface_test(void)
{
    NSError *error = nil;
    cpu_write(40960, 64);
    uint32_t color = 0xffff0000;
    for (unsigned i = 0; i < 16; i++)
        memcpy(state->vram_ptr + 40960 + i * 4, &color, 4);
    NV2AMetalSurfaceConfig c = { .format = 8,
                                 .width = 4,
                                 .height = 4,
                                 .pitch = 16,
                                 .scale = 1,
                                 .color = YES };
    NV2AMetalCachedSurface *surface = [surfaces prepareSurfaceAtAddress:40960
                                                                 config:&c
                                                                  frame:1
                                                                  error:&error];
    require(surface != nil, error);
    finish();
    assert(!surface.dirty && !surface.needsUpload);
    color = 0xff0000ff;
    for (unsigned i = 0; i < 16; i++)
        memcpy(state->vram_ptr + 40960 + i * 4, &color, 4);
    dirty_pages[10] = true;
    registers(0, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, 16,
              40960 - dma_a.address, false);
    NV2AMetalPGRAPHTextureSnapshot *snapshot = prepare();
    id<MTLBuffer> out = read_texture(snapshot, 0);
    finish();
    pixel(out, 4, 0, 0, 0, 0, 1, 1);
    assert(!surface.dirty && !surface.needsUpload && !dirty_pages[10]);
    surface = [surfaces prepareSurfaceAtAddress:40960
                                         config:&c
                                          frame:2
                                          error:&error];
    require(surface != nil, error);
    color = 0xffffff00;
    for (unsigned i = 0; i < 16; i++)
        memcpy(state->vram_ptr + 40960 + i * 4, &color, 4);
    dirty_pages[10] = true;
    snapshot = prepare();
    [surfaces cancel];
    assert(![snapshot validateCompletedWithError:&error]);
    assert(surface.needsUpload);
    snapshot = prepare();
    out = read_texture(snapshot, 0);
    finish();
    pixel(out, 4, 0, 0, 1, 1, 0, 1);
    surface = [surfaces prepareSurfaceAtAddress:40960
                                         config:&c
                                          frame:2
                                          error:&error];
    require(surface != nil, error);
    NV2AMetalClear *clearer =
        [[NV2AMetalClear alloc] initWithDevice:surfaces.commands.device
                                         error:&error];
    require(clearer != nil, error);
    NV2AMetalClearConfig clear = { .parameter = NV097_CLEAR_SURFACE_COLOR,
                                   .rect = { 0, 0, 4, 4 },
                                   .uniforms = { .color = { 0, 1, 0, 1 },
                                                 .depth = 0 } };
    require([clearer encodeColor:surface.transfer.texture
                            zeta:nil
                          config:&clear
                        commands:surfaces.commands
                           error:&error],
            error);
    require([surfaces markWritten:surface error:&error], error);
    /* A prior completed writeback may leave the same dirty-client page set.
     * It must not discard a newer GPU-owned green surface in favour of yellow
     * RAM. */
    dirty_pages[10] = true;
    snapshot = prepare();
    out = read_texture(snapshot, 0);
    finish();
    pixel(out, 4, 0, 0, 0, 1, 0, 1);
    assert(surface.dirty);
    uint32_t unchanged;
    memcpy(&unchanged, state->vram_ptr + 40960, 4);
    assert(unchanged == 0xffffff00);
    checks++;
}
static void dirty_page_and_dma_tests(void)
{
    NSError *error = nil;
    tcg_allowed = false;
    DMAObject original = dma_a;
    dma_a.address = 0;
    dma_a.limit = 65535;
    registers(0, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8, 4, 4, 65520,
              false);
    memset(state->vram_ptr + 65520, 0x22, 16);
    dirty_pages[15] = true;
    NV2AMetalPGRAPHTextureSnapshot *s = prepare();
    id<MTLBuffer> out = read_texture(s, 0);
    finish();
    pixel(out, 4, 3, 3, 0x22 / 255.f, 0x22 / 255.f, 0x22 / 255.f, 1);
    memset(state->vram_ptr + 65520, 0x77, 16);
    dirty_pages[15] = true;
    NV2AMetalPGRAPHTextureSnapshot *next = prepare();
    assert([s textureAtIndex:0].binding.texture !=
           [next textureAtIndex:0].binding.texture);
    out = read_texture(next, 0);
    finish();
    pixel(out, 4, 3, 3, 0x77 / 255.f, 0x77 / 255.f, 0x77 / 255.f, 1);
    assert(!dirty_pages[15] && dirty_checks >= 2);
    checks++;
    NV2AMetalSurfaceConfig c = { .format = 8,
                                 .width = 4,
                                 .height = 4,
                                 .pitch = 16,
                                 .scale = 1,
                                 .color = YES };
    NV2AMetalCachedSurface *surface = [surfaces prepareSurfaceAtAddress:8192
                                                                 config:&c
                                                                  frame:1
                                                                  error:&error];
    require(surface != nil, error);
    NV2AMetalClear *clearer =
        [[NV2AMetalClear alloc] initWithDevice:surfaces.commands.device
                                         error:&error];
    require(clearer != nil, error);
    NV2AMetalClearConfig clear = { .parameter = NV097_CLEAR_SURFACE_COLOR,
                                   .rect = { 0, 0, 4, 4 },
                                   .uniforms = { .color = { 1, 0, 0, 1 },
                                                 .depth = 0 } };
    require([clearer encodeColor:surface.transfer.texture
                            zeta:nil
                          config:&clear
                        commands:surfaces.commands
                           error:&error],
            error);
    require([surfaces markWritten:surface error:&error], error);
    registers(0, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8, 16, 16, 8192,
              false);
    dirty_pages[2] = true;
    assert(![adapter prepareWithError:&error] && dirty_pages[2] &&
           dirty_restores == 1);
    assert(!surfaces.commands.commandBuffer);
    checks++;
    tcg_allowed = true;
    dma_a = original;
    registers(0, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8, 4, 4, 64, false);
    dma_a.address |= 0xf0000000;
    s = prepare();
    finish();
    require([s validateCompletedWithError:&error], error);
    stage_roundtrip(s);
    dma_a = original;
    dma_a.limit = 78;
    assert(![adapter prepareWithError:&error]);
    dma_a = original;
    dma_a.dma_class = 0;
    assert(![adapter prepareWithError:&error]);
    dma_a = original;
    dma_a.address = 65535;
    assert(![adapter prepareWithError:&error]);
    dma_a = original;
    checks++;
}
static void invalid_register_tests(void)
{
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    for (unsigned kind = 0; kind < 7; kind++) {
        registers(0, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8, 4, 4, 64,
                  false);
        switch (kind) {
        case 0:
            pg->regs_[NV_PGRAPH_TEXFMT0] = (127 << 8) | (2 << 6);
            break;
        case 1:
            pg->regs_[NV_PGRAPH_TEXFMT0] &= ~NV_PGRAPH_TEXFMT0_DIMENSIONALITY;
            break;
        case 2:
            pg->regs_[NV_PGRAPH_TEXFMT0] ^= 1 << 6;
            break;
        case 3:
            pg->regs_[NV_PGRAPH_TEXFILTER0] |= NV_PGRAPH_TEXFILTER0_ASIGNED;
            break;
        case 4:
            pg->regs_[NV_PGRAPH_TEXFMT0] =
                NV_PGRAPH_TEXFMT0_BORDER_SOURCE |
                (NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8 << 8) | (2 << 6);
            break;
        case 5:
            pg->regs_[NV_PGRAPH_TEXCTL1_0] = 3 << 16;
            break;
        case 6:
            pg->regs_[NV_PGRAPH_TEXFILTER0] = 7 << 16 | 1 << 24;
            break;
        }
        assert(![adapter prepareWithError:&error] &&
               !surfaces.commands.commandBuffer);
        assert(pg->texture_dirty[0]);
    }
    [adapter flush];
    assert(adapter.cache.count == 0);
    for (unsigned i = 0; i < 4; i++)
        pg->regs_[NV_PGRAPH_TEXCTL0_0 + i * 4] = 0;
    NV2AMetalPGRAPHTextureSnapshot *s = prepare();
    assert(!s.enabledMask && !surfaces.commands.commandBuffer);
    require([s validateCompletedWithError:&error], error);
    stage_roundtrip(s);
    [adapter close];
    [adapter close];
    assert(![adapter prepareWithError:&error]);
    checks++;
}
#include "test-metal-texture-capture.h"

int main(int argc, char **argv)
{
    BOOL paletteOnly = argc == 2 && !strcmp(argv[1], "--palette-completion");
    BOOL captureOnly = argc == 2 && !strcmp(argv[1], "--capture-only");
    BOOL scaledGradientOnly =
        argc == 2 && !strcmp(argv[1], "--hilo16-scaled-gradients");
    BOOL gradientOnly = argc == 2 && !strcmp(argv[1], "--hilo16-gradients");
    BOOL rectangleGradientOnly =
        argc == 2 && !strcmp(argv[1], "--hilo16-rectangle-gradients");
    BOOL projectiveGradientOnly =
        argc == 2 && !strcmp(argv[1], "--hilo16-projective-gradients");
    BOOL borderOnly = argc == 2 && !strcmp(argv[1], "--hilo16-border");
    BOOL cubeBorderOnly = argc == 2 && !strcmp(argv[1], "--cube-border");
    BOOL convolutionOnly =
        argc == 2 && !strcmp(argv[1], "--hilo16-convolution");
    BOOL signedHILOOnly = argc == 2 && !strcmp(argv[1], "--signed-hilo16");
    BOOL signedVolumeOnly =
        argc == 2 && !strcmp(argv[1], "--signed-hilo16-volume");
    BOOL signedBorderOnly =
        argc == 2 && !strcmp(argv[1], "--signed-hilo16-border");
    BOOL signedCubeBorderOnly =
        argc == 2 && !strcmp(argv[1], "--signed-hilo16-cube-border");
    BOOL signedConvolutionOnly =
        argc == 2 && !strcmp(argv[1], "--signed-hilo16-convolution");
    assert(argc == 1 || paletteOnly || captureOnly || borderOnly ||
           cubeBorderOnly || convolutionOnly || signedHILOOnly ||
           signedVolumeOnly || signedBorderOnly || signedCubeBorderOnly ||
           signedConvolutionOnly || gradientOnly || rectangleGradientOnly ||
           projectiveGradientOnly || scaledGradientOnly);
    vram_size = borderOnly || cubeBorderOnly || signedBorderOnly ||
                        signedCubeBorderOnly || gradientOnly ||
                        projectiveGradientOnly || scaledGradientOnly ?
                    262144 :
                    65536;
    @autoreleasepool {
        NSError *error = nil;
        state = g_new0(NV2AState, 1);
        state->vram = g_new0(MemoryRegion, 1);
        assert(!posix_memalign((void **)&state->vram_ptr, getpagesize(),
                               vram_size));
        memset(state->vram_ptr, 0, vram_size);
        state->pgraph.dma_a = 16;
        state->pgraph.dma_b = 32;
        dma_a = (DMAObject){ .dma_class = NV_DMA_IN_MEMORY_CLASS,
                             .address = 4096,
                             .limit = 65535 };
        dma_b = (DMAObject){ .dma_class = NV_DMA_IN_MEMORY_CLASS,
                             .address = 12288,
                             .limit = 65535 };
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        id<MTLBuffer> vram = [commands.device
            newBufferWithBytesNoCopy:state->vram_ptr
                              length:vram_size
                             options:MTLResourceStorageModeShared
                         deallocator:nil];
        assert(vram && vram.contents == state->vram_ptr);
        surfaces = [[TextureTestSurfaces alloc] initWithCommands:commands
                                                              vram:vram
                                                      didWriteVRAM:nil
                                                             error:&error];
        require(surfaces != nil, error);
        adapter = [[NV2AMetalPGRAPHTextures alloc] initWithState:state
                                                        surfaces:surfaces
                                                           error:&error];
        require(adapter != nil, error);
        if (captureOnly) {
            texture_capture_tests();
        } else if (paletteOnly) {
            palette_completion_tests();
        } else if (scaledGradientOnly) {
            for (unsigned mode = 0; mode < 3; mode++)
                hilo16_gradient_tests(mode, 2);
        } else if (rectangleGradientOnly) {
            hilo16_gradient_tests(1, 1);
        } else if (projectiveGradientOnly) {
            hilo16_gradient_tests(2, 1);
        } else if (gradientOnly) {
            hilo16_gradient_tests(0, 1);
        } else if (signedConvolutionOnly) {
            hilo16_convolution_tests(YES);
        } else if (signedVolumeOnly) {
            hilo16_cube_volume_filter_tests(YES);
        } else if (signedBorderOnly) {
            hilo16_physical_border_tests(YES);
        } else if (signedCubeBorderOnly) {
            hilo16_cube_border_tests(YES);
        } else if (signedHILOOnly) {
            hilo16_input_filter_tests(YES);
        } else if (convolutionOnly) {
            hilo16_convolution_tests(NO);
        } else if (cubeBorderOnly) {
            hilo16_cube_border_tests(NO);
        } else if (borderOnly) {
            hilo16_physical_border_tests(NO);
        } else {
            stage_capture_tests();
            texture_capture_tests();
            layout_tests();
            compact16_register_tests();
            hilo16_register_tests();
            signed_register_tests();
            signed_subresource_tests();
            hilo16_brdf_register_tests();
            hilo16_input_filter_tests(NO);
            hilo16_cube_volume_filter_tests(NO);
            volume_mip_chain_tests();
            legacy_cropped_cube_tests();
            palette_completion_tests();
            palette_tests();
            tcg_external_surface_test();
            dirty_page_and_dma_tests();
            invalid_register_tests();
        }
        require([surfaces flushWithError:&error], error);
        adapter = nil;
        surfaces = nil;
        vram = nil;
        commands = nil;
        free(state->vram_ptr);
        g_free(state->vram);
        g_free(state);
        if (!borderOnly && !cubeBorderOnly && !convolutionOnly &&
            !signedHILOOnly && !signedVolumeOnly && !signedBorderOnly &&
            !signedCubeBorderOnly && !signedConvolutionOnly && !gradientOnly &&
            !rectangleGradientOnly && !projectiveGradientOnly &&
            !scaledGradientOnly) {
            printf("Metal 4 PGRAPH textures: %u real-register/DMA/dirty-page "
                   "groups PASS\n",
                   checks);
            printf(
                "Metal4 PGRAPH stage snapshots: %u complete roundtrips PASS\n",
                stage_snapshots);
        }
    }
    return 0;
}
