/* Native PGRAPH pixel/raster capture and GPU tests; no VM/window/application.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "hw/xbox/nv2a/pgraph/metal/pixel-pgraph.h"
#include "hw/xbox/nv2a/pgraph/metal/geometry-types.h"

static NV2AState *state;
static NV2AMetalCommands *commands;
static NV2AMetalPixelShader *shader;
static NV2AMetalPixelShader *depth_shader;
static unsigned captures, draws, binding_rejections;
static const char *pixel_case = "setup";
bool tcg_allowed = true;
uint64_t memory_region_size(MemoryRegion *mr)
{
    assert(mr == state->vram);
    return 16384;
}
DMAObject nv_dma_load(NV2AState *d, hwaddr object)
{
    assert(d == state && (object == 16 || object == 32));
    return (DMAObject){ .dma_class = NV_DMA_IN_MEMORY_CLASS, .limit = 16383 };
}
void *nv_dma_map(NV2AState *d, hwaddr object, hwaddr *length)
{
    (void)d;
    (void)object;
    (void)length;
    abort();
}
bool memory_region_test_and_clear_dirty(MemoryRegion *mr, hwaddr address,
                                        hwaddr length, unsigned client)
{
    assert(mr == state->vram && client == DIRTY_MEMORY_NV2A_TEX);
    assert(address < 16384 && length <= 16384 - address);
    return false;
}
void memory_region_set_client_dirty(MemoryRegion *mr, hwaddr address,
                                    hwaddr length, unsigned client)
{
    (void)mr;
    (void)address;
    (void)length;
    (void)client;
    abort();
}
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Pixel PGRAPH: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static void reg_float(unsigned reg, float f)
{
    memcpy(&state->pgraph.regs_[reg], &f, sizeof(f));
}
static void initialize(unsigned aa, unsigned scale)
{
    PGRAPHState *pg = &state->pgraph;
    memset(pg, 0, sizeof(*pg));
    pg->primitive_mode = PRIM_TYPE_TRIANGLES;
    pg->surface_scale_factor = scale;
    pg->surface_shape =
        (SurfaceShape){ .color_format = 8,
                        .zeta_format = NV097_SET_SURFACE_FORMAT_ZETA_Z16,
                        .clip_width = 8,
                        .clip_height = 8,
                        .anti_aliasing = aa };
    pg->surface_binding_dim.width = 8 * (aa ? 2 : 1);
    pg->surface_binding_dim.height = 8 * (aa == 2 ? 2 : 1);
    pg->regs_[NV_PGRAPH_CONTROL_0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                                     NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                                     NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                                     NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
    pg->regs_[NV_PGRAPH_CONTROL_3] = NV_PGRAPH_CONTROL_3_SHADEMODE;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG0] = PS_REGISTER_V0;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA)
                                           << 8;
    reg_float(NV_PGRAPH_ZCLIPMAX, 65535);
    pg->regs_[NV_PGRAPH_WINDOWCLIPX0] = pg->regs_[NV_PGRAPH_WINDOWCLIPY0] =
        7 << 16;
    for (unsigned i = 1; i < 8; i++) {
        pg->regs_[NV_PGRAPH_WINDOWCLIPX0 + i * 4] =
            pg->regs_[NV_PGRAPH_WINDOWCLIPY0 + i * 4] = 1;
    }
}
static NV2AMetalPGRAPHPixelState *
capture(NV2AMetalPGRAPHTextureSnapshot *textures)
{
    NSError *error = nil;
    NV2AMetalPGRAPHPixelState *p =
        [[NV2AMetalPGRAPHPixelState alloc] initWithState:&state->pgraph
                                                textures:textures
                                                  device:commands.device
                                                   error:&error];
    require(p != nil, error);
    captures++;
    return p;
}
static id<MTLTexture> target(unsigned width, unsigned height)
{
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:width
                                    height:height
                                 mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget;
    d.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [commands.device newTextureWithDescriptor:d];
    assert(t);
    return t;
}
static id<MTLTexture> depth(unsigned width, unsigned height)
{
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth16Unorm
                                     width:width
                                    height:height
                                 mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget;
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [commands.device newTextureWithDescriptor:d];
    assert(t);
    return t;
}
static void render(NV2AMetalPGRAPHPixelState *p, id<MTLTexture> color,
                   id<MTLTexture> zeta, float alpha, float z, float slope)
{
    NSError *error = nil;
    if (!commands.commandBuffer)
        require([commands beginWithError:&error] != nil, error);
    NV2AMetalVertex vertices[6] = { 0 };
    const float xy[6][2] = { { 0, 0 }, { 8, 0 }, { 0, 8 },
                             { 8, 0 }, { 8, 8 }, { 0, 8 } };
    for (unsigned i = 0; i < 6; i++) {
        vertices[i].clip[0] = xy[i][0] / 4 - 1;
        vertices[i].clip[1] = 1 - xy[i][1] / 4;
        vertices[i].clip[2] = .5f;
        vertices[i].clip[3] = 1;
        vertices[i].color[0][0] = 1;
        vertices[i].color[0][3] = alpha;
        vertices[i].fog = .25f;
        vertices[i].texcoord[0][0] = vertices[i].texcoord[0][1] = 2;
        vertices[i].texcoord[0][3] = 1;
        for (unsigned stage = 1; stage < 4; stage++) {
            unsigned mode =
                (p.uniforms.combiner.shader_stage_program >> (5 * stage)) & 31;
            if (mode == PS_TEXTUREMODES_PROJECT2D) {
                vertices[i].texcoord[stage][0] =
                    vertices[i].texcoord[stage][1] = 2;
                vertices[i].texcoord[stage][3] = 1;
            }
        }
        vertices[i].plane[0][2] = vertices[i].plane[1][2] =
            vertices[i].plane[2][2] = z;
        vertices[i].plane[0][3] = vertices[i].plane[1][3] =
            vertices[i].plane[2][3] = 1;
        vertices[i].plane[1][0] = vertices[i].plane[2][1] = 8;
        vertices[i].slope = slope;
    }
    id<MTLBuffer> v =
        [commands.device newBufferWithBytes:vertices
                                     length:sizeof(vertices)
                                    options:MTLResourceStorageModeShared];
    assert(v);
    NV2AMetalPixelUniforms u = p.uniforms;
    NV2AMetalPixelTexture textures[4] = { 0 };
    require([p copyTextureBindings:textures error:&error], error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (zeta) {
        pass.depthAttachment.texture = zeta;
        pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.clearDepth = 1;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
    }
    require(
        [(zeta ? depth_shader : shader) encodeVertices:v
                                                 count:6
                                             primitive:MTLPrimitiveTypeTriangle
                                              uniforms:&u
                                              textures:textures
                                                  pass:pass
                                             drawState:p.raster
                                              commands:commands
                                                 error:&error],
        error);
    draws++;
}
static void finish(void)
{
    NSError *error = nil;
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
}
static void pixel(id<MTLTexture> t, unsigned x, unsigned y, float r, float g,
                  float b, float a)
{
    float out[4];
    [t getBytes:out
        bytesPerRow:16
         fromRegion:MTLRegionMake2D(x, y, 1, 1)
        mipmapLevel:0];
    float expected[] = { r, g, b, a };
    for (unsigned i = 0; i < 4; i++) {
        if (fabsf(out[i] - expected[i]) > .000002f) {
            fprintf(stderr, "Case %s draw %u pixel%u,%u channel%u: %g expected %g\n",
                    pixel_case, draws, x, y, i, out[i], expected[i]);
            abort();
        }
    }
}
static void metadata_tests(void)
{
    initialize(1, 3);
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_COMBINECTL] = 8;
    for (unsigned i = 0; i < 8; i++) {
        pg->regs_[NV_PGRAPH_COMBINEFACTOR0 + i * 4] = 0x11223344 + i;
        pg->regs_[NV_PGRAPH_COMBINEFACTOR1 + i * 4] = 0x55667788 + i;
    }
    pg->regs_[NV_PGRAPH_SPECFOGFACTOR0] = 0x99aabbcc;
    pg->regs_[NV_PGRAPH_SPECFOGFACTOR1] = 0xddeeff00;
    pg->regs_[NV_PGRAPH_FOGCOLOR] = 0x778899aa;
    pg->regs_[NV_PGRAPH_SHADERCTL] = 0x000765;
    pg->regs_[NV_PGRAPH_SHADERCLIPMODE] = 0x4321;
    pg->regs_[NV_PGRAPH_CONTROL_0] |=
        37 | 6 << 8 | NV_PGRAPH_CONTROL_0_ALPHATESTENABLE;
    pg->regs_[NV_PGRAPH_SETUPRASTER] = NV_PGRAPH_SETUPRASTER_WINDOWCLIPTYPE |
                                       NV_PGRAPH_SETUPRASTER_POFFSETFILLENABLE |
                                       NV_PGRAPH_SETUPRASTER_POINTSMOOTHENABLE;
    reg_float(NV_PGRAPH_ZOFFSETBIAS, 2.5f);
    reg_float(NV_PGRAPH_ZOFFSETFACTOR, 3.5f);
    pg->surface_shape.clip_x = 2;
    pg->surface_shape.clip_y = 3;
    NV2AMetalPGRAPHPixelState *p = capture(nil);
    NV2AMetalPixelUniforms u = p.uniforms;
    assert(u.combiner.control == 8 &&
           u.combiner.constants[0][0] == 0x22 / 255.f);
    assert(u.combiner.constants[15][2] == 0x8f / 255.f &&
           u.combiner.constants[16][3] == 0x99 / 255.f);
    assert(u.combiner.constants[17][0] == 0xee / 255.f &&
           u.fog_color[3] == 0x77 / 255.f);
    assert(u.other_stage_input == 0x765 && u.textures[3].compare_mask == 4);
    assert(u.alpha_test && u.alpha_func == 6 && u.alpha_ref == 37);
    assert(u.point_sprite && u.window_clip_exclusive && u.smooth_shading);
    assert(u.depth_factor == 3.5f && u.depth_offset == 2.5f);
    assert(u.surface_scale[0] == 6 && u.surface_scale[1] == 3);
    assert(u.clip_regions[0][2] == 48 && u.clip_regions[0][3] == 24);
    memset(pg->regs_, 0, sizeof(pg->regs_));
    assert(p.uniforms.alpha_ref == 37 &&
           p.uniforms.combiner.constants[0][0] == u.combiner.constants[0][0]);
    u.combiner.constants[0][0] = 0;
    assert(p.uniforms.combiner.constants[0][0] != 0);
    for (unsigned f = 0; f < 4; f++) {
        initialize(0, 1);
        pg->surface_shape.zeta_format = f & 1 ? 2 : 1;
        pg->surface_shape.z_format =
            !(f & 2); /* Deliberately stale common field. */
        pg->regs_[NV_PGRAPH_SETUPRASTER] =
            f & 2 ? NV_PGRAPH_SETUPRASTER_Z_FORMAT : 0;
        float maximum = f & 2 ? f & 1 ? f24_max : f16_max :
                        f & 1 ? 16777215.f :
                                65535.f;
        reg_float(NV_PGRAPH_ZCLIPMAX, maximum);
        p = capture(nil);
        u = p.uniforms;
        unsigned formats[] = { NV2AMetalPixelDepthD16, NV2AMetalPixelDepthD24,
                               NV2AMetalPixelDepthF16, NV2AMetalPixelDepthF24 };
        assert(u.depth_format == formats[f] && u.clip_range[1] == maximum);
    }
    initialize(0, 1);
    pg->primitive_mode = PRIM_TYPE_LINES;
    pg->regs_[NV_PGRAPH_SETUPRASTER] = NV_PGRAPH_SETUPRASTER_POFFSETFILLENABLE;
    reg_float(NV_PGRAPH_ZOFFSETBIAS, 20);
    p = capture(nil);
    assert(!p.uniforms.depth_offset);
}
static void clip_and_alpha_tests(void)
{
    PGRAPHState *pg = &state->pgraph;
    for (unsigned aa = 0; aa < 3; aa++) {
        for (unsigned scale = 1; scale < 3; scale++) {
            for (unsigned exclusive = 0; exclusive < 2; exclusive++) {
                initialize(aa, scale);
                pg->surface_shape.clip_x = pg->surface_shape.clip_y = 1;
                pg->surface_shape.clip_width = 6;
                pg->surface_shape.clip_height = 5;
                pg->regs_[NV_PGRAPH_WINDOWCLIPX0] = 2 | 4 << 16;
                pg->regs_[NV_PGRAPH_WINDOWCLIPY0] = 3 | 5 << 16;
                pg->regs_[NV_PGRAPH_SETUPRASTER] =
                    exclusive ? NV_PGRAPH_SETUPRASTER_WINDOWCLIPTYPE : 0;
                unsigned sx = scale * (aa ? 2 : 1),
                         sy = scale * (aa == 2 ? 2 : 1);
                id<MTLTexture> t = target(8 * sx, 8 * sy);
                render(capture(nil), t, nil, 1, 32768, 0);
                finish();
                for (unsigned y = 0; y < t.height; y++)
                    for (unsigned x = 0; x < t.width; x++) {
                        bool inside = x >= 2 * sx && x < 5 * sx &&
                                      y >= 3 * sy && y < 6 * sy;
                        bool scissor =
                            x >= sx && x < 7 * sx && y >= sy && y < 6 * sy;
                        bool draw = scissor && (inside != (bool)exclusive);
                        pixel(t, x, y, draw, 0, !draw, 1);
                    }
            }
        }
    }
    const unsigned references[] = { 0, 128, 255 };
    for (unsigned function = 0; function < 8; function++) {
        for (unsigned r = 0; r < 3; r++) {
            initialize(0, 1);
            unsigned ref = references[r];
            pg->regs_[NV_PGRAPH_CONTROL_0] |=
                NV_PGRAPH_CONTROL_0_ALPHATESTENABLE | function << 8 | ref;
            bool accept[] = { false,     128 < ref,  128 == ref, 128 <= ref,
                              128 > ref, 128 != ref, 128 >= ref, true };
            id<MTLTexture> t = target(8, 8);
            render(capture(nil), t, nil, 128 / 255.f, 32768, 0);
            finish();
            pixel(t, 3, 3, accept[function], 0, !accept[function],
                  accept[function] ? 128 / 255.f : 1);
        }
    }
}
static void depth_and_fog_tests(void)
{
    initialize(0, 1);
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_CONTROL_0] |= NV_PGRAPH_CONTROL_0_ZENABLE |
                                      NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                                      7 << 16;
    pg->regs_[NV_PGRAPH_SETUPRASTER] = NV_PGRAPH_SETUPRASTER_POFFSETFILLENABLE;
    reg_float(NV_PGRAPH_ZOFFSETBIAS, 10);
    reg_float(NV_PGRAPH_ZOFFSETFACTOR, 2);
    id<MTLTexture> t = target(8, 8), z = depth(8, 8);
    NV2AMetalPGRAPHPixelState *p = capture(nil);
    assert(p.raster.requiresDepth);
    render(p, t, z, 1, 32768, 3);
    NSError *error = nil;
    id<MTLBuffer> out =
        [commands.device newBufferWithLength:8 * 256
                                     options:MTLResourceStorageModeShared];
    assert(out);
    require([commands addResource:out error:&error], error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:z
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(8, 8, 1)
                        toBuffer:out
               destinationOffset:0
          destinationBytesPerRow:256
        destinationBytesPerImage:0
                         options:MTLBlitOptionNone];
    [e endEncoding];
    finish();
    uint16_t word;
    memcpy(&word, (unsigned char *)out.contents + 3 * 256 + 3 * 2, 2);
    assert(word == 32784);
    initialize(0, 1);
    pg->regs_[NV_PGRAPH_FOGCOLOR] = 0xff224466;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG0] = PS_REGISTER_FOG;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG1] = (PS_REGISTER_FOG | PS_CHANNEL_ALPHA)
                                           << 8;
    t = target(8, 8);
    render(capture(nil), t, nil, 1, 32768, 0);
    finish();
    pixel(t, 3, 3, 0x22 / 255.f, 0x44 / 255.f, 0x66 / 255.f, .25f);
}
static void combiner_and_unbound_clip_tests(void)
{
    initialize(0, 1);
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_COMBINECTL] = 1;
    pg->regs_[NV_PGRAPH_COMBINECOLORI0] = PS_REGISTER_C0 << 24 | PS_REGISTER_ONE
                                                                     << 16;
    pg->regs_[NV_PGRAPH_COMBINECOLORO0] = PS_REGISTER_R0 << 4;
    pg->regs_[NV_PGRAPH_COMBINEALPHAI0] =
        (PS_REGISTER_C1 | PS_CHANNEL_ALPHA) << 24 | PS_REGISTER_ONE << 16;
    pg->regs_[NV_PGRAPH_COMBINEALPHAO0] = PS_REGISTER_R0 << 4;
    pg->regs_[NV_PGRAPH_COMBINEFACTOR0] = 0x80775533;
    pg->regs_[NV_PGRAPH_COMBINEFACTOR1] = 0x40000000;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG0] = PS_REGISTER_R0;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG1] = (PS_REGISTER_R0 | PS_CHANNEL_ALPHA)
                                           << 8;
    id<MTLTexture> t = target(8, 8);
    render(capture(nil), t, nil, 1, 32768, 0);
    finish();
    pixel(t, 3, 3, 0x77 / 255.f, 0x55 / 255.f, 0x33 / 255.f, 0x40 / 255.f);
    initialize(0, 1);
    pg->regs_[NV_PGRAPH_COMBINESPECFOG0] = PS_REGISTER_C0;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG1] = (PS_REGISTER_C1 | PS_CHANNEL_ALPHA)
                                           << 8;
    pg->regs_[NV_PGRAPH_SPECFOGFACTOR0] = 0x004080c0;
    pg->regs_[NV_PGRAPH_SPECFOGFACTOR1] = 0xa0000000;
    t = target(8, 8);
    render(capture(nil), t, nil, 1, 32768, 0);
    finish();
    pixel(t, 3, 3, 0x40 / 255.f, 0x80 / 255.f, 0xc0 / 255.f, 0xa0 / 255.f);
    for (unsigned mask = 0; mask < 2; mask++) {
        initialize(0, 1);
        pg->regs_[NV_PGRAPH_SHADERPROG] = PS_TEXTUREMODES_CLIPPLANE;
        pg->regs_[NV_PGRAPH_SHADERCLIPMODE] = mask;
        t = target(8, 8);
        render(capture(nil), t, nil, 1, 32768, 0);
        finish();
        pixel(t, 3, 3, !mask, 0, mask, 1);
    }
}
static NSData *legacy_pixel_fixture(NSData *current, unsigned version);

static void typed_clear_texture_probe(NV2AMetalPGRAPHPixelState *p);
static void texture_snapshot_test(unsigned mask, unsigned index,
                                  unsigned hilo_format)
{
    initialize(0, 1);
    PGRAPHState *pg = &state->pgraph;
    NSError *error = nil;
    id<MTLBuffer> ram =
        [commands.device newBufferWithLength:16384
                                     options:MTLResourceStorageModeShared];
    assert(ram);
    state->vram_ptr = ram.contents;
    state->vram = g_new0(MemoryRegion, 1);
    pg->dma_a = 16;
    pg->dma_b = 32;
    for (unsigned i = 0; i < 16; i++) {
        uint32_t color = 0xff552211;
        memcpy(state->vram_ptr + 64 + i * 4, &color, 4);
    }
    pg->regs_[NV_PGRAPH_SHADERPROG] = PS_TEXTUREMODES_PROJECT2D << (5 * index);
    pg->regs_[NV_PGRAPH_TEXCTL0_0 + index * 4] = NV_PGRAPH_TEXCTL0_0_ENABLE;
    pg->regs_[NV_PGRAPH_TEXCTL1_0 + index * 4] = 16 << 16;
    pg->regs_[NV_PGRAPH_TEXFMT0 + index * 4] =
        NV_PGRAPH_TEXFMT0_BORDER_SOURCE | (2 << 6) |
        ((hilo_format ? hilo_format :
                        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8)
         << 8) |
        1 << 16 |
        (hilo_format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16 ?
             (2 << 20 | 2 << 24) :
             0);
    pg->regs_[NV_PGRAPH_TEXIMAGERECT0 + index * 4] = 4 << 16 | 4;
    pg->regs_[NV_PGRAPH_TEXOFFSET0 + index * 4] = 64;
    pg->regs_[NV_PGRAPH_TEXFILTER0 + index * 4] = 1 << 16 | 1 << 24;
    const unsigned flags[] = { NV_PGRAPH_TEXFILTER0_RSIGNED,
                               NV_PGRAPH_TEXFILTER0_GSIGNED,
                               NV_PGRAPH_TEXFILTER0_BSIGNED,
                               NV_PGRAPH_TEXFILTER0_ASIGNED };
    for (unsigned k = 0; k < 4; k++)
        if (mask & (1u << k))
            pg->regs_[NV_PGRAPH_TEXFILTER0 + index * 4] |= flags[k];
    pg->regs_[NV_PGRAPH_TEXADDRESS0 + index * 4] = 3 | 3 << 8 | 3 << 16;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG0] = PS_REGISTER_T0 + index;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG1] =
        (PS_REGISTER_T0 + index | PS_CHANNEL_ALPHA) << 8;
    NV2AMetalSurfaceCache *surfaces =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:ram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(surfaces != nil, error);
    NV2AMetalPGRAPHTextures *textures =
        [[NV2AMetalPGRAPHTextures alloc] initWithState:state
                                              surfaces:surfaces
                                                 error:&error];
    require(textures != nil, error);
    NV2AMetalPGRAPHTextureSnapshot *snapshot =
        [textures prepareWithError:&error];
    require(snapshot != nil, error);
    NV2AMetalPGRAPHPixelState *p = capture(snapshot);
    typed_clear_texture_probe(p);
    require([surfaces submitWithError:&error], error);
    require([surfaces waitUntilIdleWithError:&error], error);
    NSData *scalar = p.snapshotData;
    NSData *content = [snapshot snapshotWithCommands:commands error:&error];
    require(content != nil, error);
    assert(p.uniforms.textures[index].signed_channels == mask &&
           p.uniforms.hilo16_mask == (hilo_format ? 1u << index : 0));
    if (hilo_format) {
        for (unsigned version = 1; version <= 5; version++) {
            NSData *old = legacy_pixel_fixture(scalar, version);
            assert(![NV2AMetalPGRAPHPixelState
                validateBoundSnapshot:old
                              control:p.raster.config.control[0]
                              stencil:p.raster.config.control[1]
                          textureMask:1u << index
                             textures:content]);
            binding_rejections++;
        }
        NSMutableData *lost = [scalar mutableCopy];
        stl_be_p((uint8_t *)lost.mutableBytes + 100 +
                     offsetof(NV2AMetalPixelUniforms, hilo16_mask),
                 0);
        assert(![NV2AMetalPGRAPHTextureSnapshot
            validateSnapshot:content
                    uniforms:&(NV2AMetalPixelUniforms){ 0 }
                       error:NULL]);
        assert(![NV2AMetalPGRAPHPixelState
            validateBoundSnapshot:lost
                          control:p.raster.config.control[0]
                          stencil:p.raster.config.control[1]
                      textureMask:1u << index
                         textures:content]);
        binding_rejections++;
        lost = [content mutableCopy];
        stl_be_p((uint8_t *)lost.mutableBytes + 20,
                 ldl_be_p((const uint8_t *)lost.bytes + 20) & ~8u);
        assert(![NV2AMetalPGRAPHPixelState
            validateBoundSnapshot:scalar
                          control:p.raster.config.control[0]
                          stencil:p.raster.config.control[1]
                      textureMask:1u << index
                         textures:lost]);
        binding_rejections++;
    }
    NV2AMetalDrawConfig raster = p.raster.config;
    assert([NV2AMetalPGRAPHPixelState validateBoundSnapshot:scalar
                                                    control:raster.control[0]
                                                    stencil:raster.control[1]
                                                textureMask:1u << index
                                                   textures:content]);
    NSMutableData *mismatch = [scalar mutableCopy];
    stl_be_p((uint8_t *)mismatch.mutableBytes + 100 + (108 + 37) * 4 +
                 index * sizeof(NV2AMetalTextureStage),
             mask ^ 1);
    assert([NV2AMetalPGRAPHPixelState validateSnapshot:mismatch
                                                 error:NULL] == !hilo_format);
    assert(![NV2AMetalPGRAPHPixelState validateBoundSnapshot:mismatch
                                                     control:raster.control[0]
                                                     stencil:raster.control[1]
                                                 textureMask:1u << index
                                                    textures:content]);

    // Valid scalar states must match their owner; HILO signedness is invalid.
    for (unsigned test = 0; test < 9; test++) {
        NV2AMetalPixelUniforms changed = p.uniforms;
        NV2AMetalTextureStage *stage = &changed.textures[index];
        switch (test) {
        case 0:
            stage->signed_channels ^= 1;
            break;
        case 1:
            stage->scale = 2;
            break;
        case 2:
            stage->bump_scale = .25f;
            break;
        case 3:
            stage->sampling.address[0] = 1;
            break;
        case 4:
            stage->sampling.min_linear = 1;
            break;
        case 5:
            stage->color_key ^= 1;
            break;
        case 6:
            stage->colorkey_mode = COLOR_KEY_KILL_ALPHA;
            break;
        case 7:
            stage->sampling.border_color[0] = .25f;
            break;
        case 8:
            stage->bump_matrix[0] = .25f;
            break;
        }
        NSMutableData *bad = [scalar mutableCopy];
        const uint8_t *bytes = (const uint8_t *)&changed;
        for (unsigned offset = 0; offset < sizeof(changed); offset += 4) {
            uint32_t word;
            memcpy(&word, bytes + offset, 4);
            stl_be_p((uint8_t *)bad.mutableBytes + 100 + offset, word);
        }
        assert([NV2AMetalPGRAPHPixelState validateSnapshot:bad error:NULL] ==
               (!hilo_format || test != 0));
        assert(!commands.commandBuffer);
        error = nil;
        assert(![[NV2AMetalPGRAPHPixelState alloc]
            initWithSnapshot:bad
                    textures:p.textureSnapshot
                      device:commands.device
                       error:&error]);
        assert(error && !commands.commandBuffer &&
               [p.snapshotData isEqualToData:scalar]);
        binding_rejections++;
    }
    assert(![NV2AMetalPGRAPHPixelState validateBoundSnapshot:scalar
                                                     control:raster.control[0]
                                                     stencil:raster.control[1]
                                                 textureMask:1u << index
                                                    textures:nil]);
    binding_rejections++;
    const uint8_t empty_stage[] = {
        'M', '4', 'T', 'S', 0, 0, 0, 2, 0, 0, 0, 0
    };
    NSData *empty = [NSData dataWithBytes:empty_stage
                                   length:sizeof(empty_stage)];
    assert([NV2AMetalPGRAPHTextureSnapshot validateSnapshot:empty error:NULL]);
    assert(![NV2AMetalPGRAPHPixelState validateBoundSnapshot:scalar
                                                     control:raster.control[0]
                                                     stencil:raster.control[1]
                                                 textureMask:1u << index
                                                    textures:empty]);
    binding_rejections++;
    snapshot = nil;
    [textures flush];
    /* Destroy/mutate the register owner before draw; the capture must survive.
     */
    memset(pg->regs_, 0, sizeof(pg->regs_));
    id<MTLTexture> t = target(8, 8);
    require([surfaces prepareGPUReadAtAddress:64 length:64 error:&error],
            error);
    render(p, t, nil, 1, 32768, 0);
    require([surfaces submitWithError:&error], error);
    require([surfaces waitUntilIdleWithError:&error], error);
    float r = (mask & 1 ? 2 : 1) * 0x55 / 255.f;
    float g = (mask & 2 ? 2 : 1) * 0x22 / 255.f;
    float b = (mask & 4 ? 2 : 1) * 0x11 / 255.f;
    float a = mask & 8 ? 0 : 1;
    if (hilo_format) {
        r = 0xff55 / 65535.f;
        g = b = 0x2211 / 65535.f;
    }
    pixel(t, 3, 3, r, g, b, a);
    NV2AMetalPGRAPHTextureSnapshot *restored =
        [[NV2AMetalPGRAPHTextureSnapshot alloc] initWithSnapshot:content
                                                        commands:commands
                                                           error:&error];
    require(restored != nil, error);
    p = [[NV2AMetalPGRAPHPixelState alloc] initWithSnapshot:scalar
                                                   textures:restored
                                                     device:commands.device
                                                      error:&error];
    require(p != nil, error);
    assert(p.uniforms.textures[index].signed_channels == mask &&
           [p.snapshotData isEqualToData:scalar]);
    require([surfaces prepareGPUReadAtAddress:64 length:64 error:&error],
            error);
    render(p, t, nil, 1, 32768, 0);
    require([surfaces submitWithError:&error], error);
    require([surfaces waitUntilIdleWithError:&error], error);
    pixel(t, 3, 3, r, g, b, a);
    // Shader-only clip compare bits may change while retaining the binding.
    NSMutableData *rebound = [scalar mutableCopy];
    stl_be_p((uint8_t *)rebound.mutableBytes + 100 +
                 offsetof(NV2AMetalPixelUniforms, textures) +
                 index * sizeof(NV2AMetalTextureStage) +
                 offsetof(NV2AMetalTextureStage, compare_mask),
             1);
    NV2AMetalPGRAPHPixelState *clip =
        [[NV2AMetalPGRAPHPixelState alloc] initWithSnapshot:rebound
                                                   textures:restored
                                                     device:commands.device
                                                      error:&error];
    require(clip != nil, error);
    assert(clip.uniforms.textures[index].compare_mask == 1 &&
           [clip.snapshotData isEqualToData:rebound]);
    require([surfaces prepareGPUReadAtAddress:64 length:64 error:&error],
            error);
    render(clip, t, nil, 1, 32768, 0);
    require([surfaces submitWithError:&error], error);
    require([surfaces waitUntilIdleWithError:&error], error);
    pixel(t, 3, 3, r, g, b, a);
    if (!mask && !hilo_format) {
        for (unsigned version = 1; version <= 3; version++) {
            NSData *legacy = legacy_pixel_fixture(scalar, version);
            assert([NV2AMetalPGRAPHPixelState
                validateBoundSnapshot:legacy
                              control:raster.control[0]
                              stencil:raster.control[1]
                          textureMask:1u << index
                             textures:content]);
            p = [[NV2AMetalPGRAPHPixelState alloc]
                initWithSnapshot:legacy
                        textures:restored
                          device:commands.device
                           error:&error];
            require(p != nil, error);
            assert(!p.uniforms.textures[index].signed_channels &&
                   [p.snapshotData isEqualToData:legacy]);
            require([surfaces prepareGPUReadAtAddress:64
                                               length:64
                                                error:&error],
                    error);
            render(p, t, nil, 1, 32768, 0);
            require([surfaces submitWithError:&error], error);
            require([surfaces waitUntilIdleWithError:&error], error);
            pixel(t, 3, 3, r, g, b, a);
        }
    }
    [textures close];
    require([surfaces flushWithError:&error], error);
    g_free(state->vram);
    state->vram = NULL;
    state->vram_ptr = NULL;
}
static NSData *legacy_pixel_fixture(NSData *current, unsigned version)
{
    assert(version >= 1 && version <= 5 && current.length == 100 + 1332);
    if (version >= 4) {
        NSMutableData *old = [current mutableCopy];
        old.length -= version == 5 ? 4 : 8;
        stl_be_p((uint8_t *)old.mutableBytes + 4, version);
        stl_be_p((uint8_t *)old.mutableBytes + 8, version == 5 ? 332 : 331);
        return old;
    }
    unsigned header = version == 1 ? 92 : 100;
    NSMutableData *old = [NSMutableData dataWithBytes:current.bytes
                                               length:header];
    stl_be_p((uint8_t *)old.mutableBytes + 4, version);
    stl_be_p((uint8_t *)old.mutableBytes + 8, version == 3 ? 327 : 323);
    [old appendData:[current subdataWithRange:NSMakeRange(100, 108 * 4)]];
    for (unsigned i = 0; i < 4; i++) {
        [old appendData:[current subdataWithRange:NSMakeRange(
                                                      100 + (108 + i * 38) * 4,
                                                      37 * 4)]];
    }
    [old appendData:[current
                        subdataWithRange:NSMakeRange(100 + 260 * 4,
                                                     (version == 3 ? 71 : 67) *
                                                         4)]];
    return old;
}

static void eye_vector_capture_tests(void)
{
    initialize(0, 1);
    PGRAPHState *pg = &state->pgraph;
    reg_float(NV_PGRAPH_EYEVEC0, .25f);
    reg_float(NV_PGRAPH_EYEVEC1, -2);
    reg_float(NV_PGRAPH_EYEVEC2, 3.5f);
    NV2AMetalPGRAPHPixelState *state = capture(nil);
    NSData *snapshot = state.snapshotData;
    assert(snapshot.length == 100 + 1332 &&
           ldl_be_p((const uint8_t *)snapshot.bytes + 4) == 6 &&
           ldl_be_p((const uint8_t *)snapshot.bytes + 8) == 333);
    NSError *error = nil;
    reg_float(NV_PGRAPH_EYEVEC0, 9);
    NV2AMetalPGRAPHPixelState *restored =
        [[NV2AMetalPGRAPHPixelState alloc] initWithSnapshot:snapshot
                                                   textures:nil
                                                     device:commands.device
                                                      error:&error];
    require(restored != nil, error);
    NV2AMetalPixelUniforms u = restored.uniforms;
    assert(u.eye_vector[0] == .25f && u.eye_vector[1] == -2 &&
           u.eye_vector[2] == 3.5f && !u.legacy_spec_const &&
           [restored.snapshotData isEqualToData:snapshot]);
    for (unsigned version = 1; version <= 5; version++) {
        unsigned header = version == 1 ? 92 : 100;
        NSMutableData *legacy =
            [legacy_pixel_fixture(snapshot, version) mutableCopy];
        if (version < 3) {
            stl_be_p((uint8_t *)legacy.mutableBytes + header + 4,
                     PS_TEXTUREMODES_DOT_RFLCT_SPEC_CONST << 15);
        }
        restored =
            [[NV2AMetalPGRAPHPixelState alloc] initWithSnapshot:legacy
                                                       textures:nil
                                                         device:commands.device
                                                          error:&error];
        require(restored != nil, error);
        u = restored.uniforms;
        assert(u.eye_vector[0] == (version >= 3 ? .25f : 0) &&
               u.eye_vector[1] == (version >= 3 ? -2 : 0) &&
               u.eye_vector[2] == (version >= 3 ? 3.5f : 0) &&
               u.legacy_spec_const == (version < 3) &&
               [restored.snapshotData isEqualToData:legacy]);
        for (unsigned i = 0; i < 4; i++)
            assert(!u.textures[i].signed_channels);
    }
    for (NSUInteger length = 0; length < snapshot.length; length++)
        assert(![NV2AMetalPGRAPHPixelState
            validateSnapshot:[snapshot subdataWithRange:NSMakeRange(0, length)]
                       error:NULL]);
    NSMutableData *bad = [snapshot mutableCopy];
    stl_be_p((uint8_t *)bad.mutableBytes + 100 +
                 offsetof(NV2AMetalPixelUniforms, two_side),
             2);
    assert(![NV2AMetalPGRAPHPixelState validateSnapshot:bad error:NULL]);
    // Eye registers unused by this shader still preserve raw float bits.
    pg->regs_[NV_PGRAPH_EYEVEC0] = 0x80000000;
    pg->regs_[NV_PGRAPH_EYEVEC1] = 0x7fc12345;
    pg->regs_[NV_PGRAPH_EYEVEC2] = 0x7f800000;
    snapshot = capture(nil).snapshotData;
    const uint8_t *tail = (const uint8_t *)snapshot.bytes + 100 +
                          offsetof(NV2AMetalPixelUniforms, eye_vector);
    assert((uint32_t)ldl_be_p(tail) == 0x80000000 &&
           (uint32_t)ldl_be_p(tail + 4) == 0x7fc12345 &&
           (uint32_t)ldl_be_p(tail + 8) == 0x7f800000);
}

static void two_side_capture_tests(void)
{
    /* render() emits a clockwise clip-space triangle. The existing native
     * DrawState selects CCW when FRONTFACE is set, CW when it is clear. */
    unsigned cases = 0;
    for (unsigned frontSelect = 0; frontSelect < 2; frontSelect++) {
        for (unsigned enabled = 0; enabled < 2; enabled++) {
            initialize(0, 1);
            PGRAPHState *pg = &state->pgraph;
            pg->regs_[NV_PGRAPH_SETUPRASTER] =
                (frontSelect ? NV_PGRAPH_SETUPRASTER_FRONTFACE : 0) |
                (enabled ? NV_PGRAPH_SETUPRASTER_TWO_SIDE : 0);
            NV2AMetalPGRAPHPixelState *fresh = capture(nil);
            NSData *wire = fresh.snapshotData;
            assert(fresh.uniforms.two_side == enabled);
            NSError *error = nil;
            NV2AMetalPGRAPHPixelState *restored =
                [[NV2AMetalPGRAPHPixelState alloc]
                    initWithSnapshot:wire
                            textures:nil
                              device:commands.device
                               error:&error];
            require(restored != nil, error);
            assert([wire isEqualToData:restored.snapshotData]);
            pg->regs_[NV_PGRAPH_SETUPRASTER] ^= NV_PGRAPH_SETUPRASTER_TWO_SIDE;
            NV2AMetalPGRAPHPixelState *rebound =
                [fresh recaptureShaderWithState:pg
                                         device:commands.device
                                          error:&error];
            require(rebound != nil, error);
            assert(rebound.uniforms.two_side == enabled &&
                   [wire isEqualToData:rebound.snapshotData]);
            for (NV2AMetalPGRAPHPixelState *p in
                 @[ fresh, restored, rebound ]) {
                id<MTLTexture> color = target(8, 8);
                render(p, color, nil, 1, 32768, 0);
                finish();
                pixel(color, 2, 2, !enabled || !frontSelect, 0, 0,
                      !enabled || !frontSelect);
                cases++;
            }
            for (unsigned version = 1; version <= 4; version++) {
                NSData *old = legacy_pixel_fixture(wire, version);
                NV2AMetalPGRAPHPixelState *legacy =
                    [[NV2AMetalPGRAPHPixelState alloc]
                        initWithSnapshot:old
                                textures:nil
                                  device:commands.device
                                   error:&error];
                require(legacy != nil, error);
                assert(!legacy.uniforms.two_side &&
                       [old isEqualToData:legacy.snapshotData]);
                id<MTLTexture> color = target(8, 8);
                render(legacy, color, nil, 1, 32768, 0);
                finish();
                pixel(color, 2, 2, 1, 0, 0, 1);
                cases++;
            }
            for (unsigned value = 0; value < 3; value++) {
                if (value == enabled)
                    continue;
                NSMutableData *bad = [wire mutableCopy];
                stl_be_p((uint8_t *)bad.mutableBytes + 100 +
                             offsetof(NV2AMetalPixelUniforms, two_side),
                         value);
                assert(![NV2AMetalPGRAPHPixelState validateSnapshot:bad
                                                              error:NULL]);
            }
            NSMutableData *bad = [wire mutableCopy];
            uint8_t *bytes = bad.mutableBytes;
            stl_be_p(bytes + 13 * 4,
                     ldl_be_p(bytes + 13 * 4) ^ NV_PGRAPH_SETUPRASTER_TWO_SIDE);
            assert(![NV2AMetalPGRAPHPixelState validateSnapshot:bad
                                                          error:NULL]);
        }
    }
    assert(cases == 28);
    printf("Metal4 two-sided pixel capture/legacy/rebind: %u GPU draws PASS\n",
           cases);
}

static void rejection_tests(void)
{
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    for (unsigned i = 0; i < 9; i++) {
        initialize(0, 1);
        switch (i) {
        case 0:
            pg->surface_binding_dim.width = -1;
            break;
        case 1:
            pg->surface_scale_factor = UINT32_MAX;
            break;
        case 2:
            pg->surface_shape.anti_aliasing = 3;
            break;
        case 3:
            pg->primitive_mode = 0;
            break;
        case 4:
            pg->surface_shape.zeta_format = 0;
            break;
        case 5:
            pg->regs_[NV_PGRAPH_COMBINECTL] = 9;
            break;
        case 6:
            pg->regs_[NV_PGRAPH_COMBINESPECFOG0] =
                pg->regs_[NV_PGRAPH_COMBINESPECFOG1] = 0;
            break;
        case 7:
            reg_float(NV_PGRAPH_ZCLIPMIN, NAN);
            break;
        case 8:
            pg->regs_[NV_PGRAPH_SETUPRASTER] =
                NV_PGRAPH_SETUPRASTER_FRONTFACEMODE;
            break;
        }
        assert(![[NV2AMetalPGRAPHPixelState alloc] initWithState:pg
                                                        textures:nil
                                                          device:commands.device
                                                           error:&error]);
        assert(!commands.commandBuffer);
    }
}

static void point_sprite_capture_tests(void)
{
    unsigned restored_count = 0;
    for (unsigned primitive = PRIM_TYPE_POINTS; primitive <= PRIM_TYPE_POLYGON;
         primitive++)
        for (unsigned front = 0; front < 3; front++)
            for (unsigned back = 0; back < 3; back++)
                for (unsigned enabled = 0; enabled < 2; enabled++) {
                    initialize(0, 1);
                    PGRAPHState *pg = &state->pgraph;
                    pg->primitive_mode = primitive;
                    pg->regs_[NV_PGRAPH_SETUPRASTER] =
                        front | back << 2 |
                        (enabled ? NV_PGRAPH_SETUPRASTER_POINTSMOOTHENABLE : 0);
                    NV2AMetalPGRAPHPixelState *p = capture(nil);
                    assert(p.uniforms.point_sprite == enabled);
                    NSData *saved = p.snapshotData;
                    assert(ldl_be_p((const uint8_t *)saved.bytes + 4) == 6);
                    for (unsigned rectangle = 0; rectangle < 2; rectangle++) {
                        NSMutableData *data = [saved mutableCopy];
                        size_t offset =
                            25 * 4 +
                            offsetof(NV2AMetalPixelUniforms, textures) +
                            3 * sizeof(NV2AMetalTextureStage) +
                            offsetof(NV2AMetalTextureStage, rectangle);
                        stl_be_p((uint8_t *)data.mutableBytes + offset,
                                 rectangle);
                        NSError *error = nil;
                        NV2AMetalPGRAPHPixelState *restored =
                            [[NV2AMetalPGRAPHPixelState alloc]
                                initWithSnapshot:data
                                        textures:nil
                                          device:commands.device
                                           error:&error];
                        require(restored != nil, error);
                        assert(restored.uniforms.point_sprite == enabled &&
                               restored.uniforms.textures[3].rectangle ==
                                   rectangle &&
                               [restored.snapshotData isEqualToData:data]);
                        /* The capture stores the enable bit; actual point
                         * topology is known only when each stream is drawn. */
                        for (unsigned mode = 0; mode < 3; mode++)
                            assert([restored uniformsForPolygon:mode]
                                       .point_sprite == enabled);
                        pg->regs_[NV_PGRAPH_SETUPRASTER] ^=
                            NV_PGRAPH_SETUPRASTER_POINTSMOOTHENABLE;
                        assert(restored.uniforms.point_sprite == enabled);
                        restored_count++;
                    }
                    NV2AMetalPixelUniforms invalid = p.uniforms;
                    invalid.point_sprite = 2;
                    NSError *error = nil;
                    assert(!nv2a_metal_pixel_validate(&invalid, &error) &&
                           error);
                }
    assert(restored_count == 360);
    printf("Metal4 point-sprite immutable enable/rectangle captures: %u "
           "roundtrips PASS\n",
           restored_count);
}

#include "test-metal-pixel-clear-clone.h"
#include "test-metal-depth-stencil-cache.h"

int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        state = g_new0(NV2AState, 1);
        commands = [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        shader = [[NV2AMetalPixelShader alloc]
            initWithDevice:commands.device
               colorFormat:MTLPixelFormatRGBA32Float
               depthFormat:MTLPixelFormatInvalid
               sampleCount:1
                     error:&error];
        require(shader != nil, error);
        depth_shader = [[NV2AMetalPixelShader alloc]
            initWithDevice:commands.device
               colorFormat:MTLPixelFormatRGBA32Float
               depthFormat:MTLPixelFormatDepth16Unorm
               sampleCount:1
                     error:&error];
        require(depth_shader != nil, error);
        depth_stencil_cache_tests();
        typed_clear_tests();
        pixel_case = "point_sprite_capture_tests";
        point_sprite_capture_tests();
        pixel_case = "metadata_tests";
        metadata_tests();
        pixel_case = "clip_and_alpha_tests";
        clip_and_alpha_tests();
        pixel_case = "depth_and_fog_tests";
        depth_and_fog_tests();
        pixel_case = "combiner_and_unbound_clip_tests";
        combiner_and_unbound_clip_tests();
        pixel_case = "eye_vector_capture_tests";
        eye_vector_capture_tests();
        pixel_case = "texture_snapshot_test";
        for (unsigned index = 0; index < 4; index++)
            for (unsigned mask = 0; mask < 16; mask++)
                texture_snapshot_test(mask, index, 0);
        for (unsigned index = 0; index < 4; index++) {
            texture_snapshot_test(
                0, index, NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16);
            texture_snapshot_test(
                0, index, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16);
        }
        pixel_case = "two_side_capture_tests";
        two_side_capture_tests();
        pixel_case = "rejection_tests";
        rejection_tests();
        assert(binding_rejections == 848);
        assert(typed_clear_cases == 1056 && typed_clear_images == 16);
        printf("Typed clear final: %u exact scalar/texture comparisons, %u GPU image pairs PASS\n",
               typed_clear_cases, typed_clear_images);
        printf("Metal4 pixel bindings: %u rejected mismatches, 72 compare-only "
               "restores PASS\n",
               binding_rejections);
        g_free(state);
        printf(
            "Metal 4 PGRAPH pixel: %u immutable captures, %u GPU draws PASS\n",
            captures, draws);
    }
    return 0;
}
