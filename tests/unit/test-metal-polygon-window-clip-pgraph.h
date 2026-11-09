/* Polygon window clipping against the exact former fragment source.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_POLYGON_WINDOW_CLIP_PGRAPH_H
#define TEST_METAL_POLYGON_WINDOW_CLIP_PGRAPH_H
#include "test-metal-polygon-window-reference.h"
#define metal_shader_source pwg_production_source
#include "pixel-shader-source.h"
#undef metal_shader_source

static BOOL pwg_scope, pwg_reference, pwg_fail_emit;
static id<MTLLibrary> pwg_old_library;
static NSError *pwg_failure;
static unsigned pwg_pipelines, pwg_compact, pwg_sampling;
static NSUInteger pwg_mip_count;
static NV2AMetalSamplingUniforms pwg_last_sampling;
typedef id (*PolygonWindowPgraphPipeline)(id, SEL, unsigned, id, unsigned,
                                          const void *,
                                          NV2AMetalPixelRasterClass, NSError **)
    __attribute__((ns_returns_retained));
static PolygonWindowPgraphPipeline pwg_pipeline_original;
static id pwg_pipeline(id owner, SEL selector, unsigned topology, id state,
                       unsigned post, const void *key,
                       NV2AMetalPixelRasterClass raster, NSError **error)
    __attribute__((ns_returns_retained));
static id pwg_pipeline(id owner, SEL selector, unsigned topology, id state,
                       unsigned post, const void *key,
                       NV2AMetalPixelRasterClass raster, NSError **error)
{
    if (!pwg_scope || !pwg_reference)
        return pwg_pipeline_original(owner, selector, topology, state, post,
                                     key, raster, error);
    id<MTLLibrary> saved = [owner valueForKey:@"library"];
    [owner setValue:pwg_old_library forKey:@"library"];
    @try {
        pwg_pipelines++;
        return pwg_pipeline_original(owner, selector, topology, state, post,
                                     key, raster, error);
    } @finally {
        [owner setValue:saved forKey:@"library"];
    }
}
static id (*pwg_prepare_original)(id, SEL, NV2AMetalGeometryResult *,
                                  NSUInteger, NSUInteger,
                                  const NV2AMetalPixelUniforms *,
                                  const NV2AMetalPixelTexture *, id, id,
                                  NV2AMetalPixelRasterClass, BOOL, id,
                                  NSError **);
static id pwg_prepare(id owner, SEL selector, NV2AMetalGeometryResult *geometry,
                      NSUInteger first, NSUInteger count,
                      const NV2AMetalPixelUniforms *u,
                      const NV2AMetalPixelTexture *textures, id pass, id state,
                      NV2AMetalPixelRasterClass raster, BOOL ignore,
                      id commands, NSError **error)
{
    id packet = pwg_prepare_original(owner, selector, geometry, first, count, u,
                                     textures, pass, state, raster, ignore,
                                     commands, error);
    if (packet && pwg_scope) {
        pwg_compact += geometry.compactPolygons && geometry.expandedPolygons;
        if (((u->combiner.shader_stage_program >> 5) & 31) ==
            PS_TEXTUREMODES_DPNDNT_AR) {
            pwg_mip_count = textures[1].texture.mipmapLevelCount;
            pwg_last_sampling = u->textures[1].sampling;
        }
        pwg_sampling += u->textures[0].sampling.enabled == 1 &&
                        u->textures[1].sampling.enabled == 1 &&
                        textures[1].texture.mipmapLevelCount == 5 &&
                        u->textures[1].sampling.min_linear == 1 &&
                        u->textures[1].sampling.mag_linear == 1 &&
                        u->textures[1].sampling.mip_filter == 2 &&
                        u->textures[1].sampling.anisotropy == 4 &&
                        u->textures[1].sampling.lod_bias == 1.5f &&
                        ((u->combiner.shader_stage_program >> 5) & 31) ==
                            PS_TEXTUREMODES_DPNDNT_AR;
    }
    return packet;
}
static BOOL (*pwg_emit_original)(id, SEL, id, id, NSError **);
static BOOL pwg_emit(id owner, SEL selector, id encoder, id commands,
                     NSError **error)
{
    BOOL ok = pwg_emit_original(owner, selector, encoder, commands, error);
    if (ok && pwg_scope && pwg_fail_emit) {
        pwg_fail_emit = NO;
        if (error)
            *error = pwg_failure;
        return NO; /* Real GPU emission, then transactional rejection. */
    }
    return ok;
}

static NSUInteger pwg_morton(unsigned x, unsigned y)
{
    NSUInteger result = 0;
    for (unsigned bit = 0; bit < 4; bit++) {
        result |= (NSUInteger)((x >> bit) & 1) << (2 * bit);
        result |= (NSUInteger)((y >> bit) & 1) << (2 * bit + 1);
    }
    return result;
}
static void pwg_textures(void)
{
    PGRAPHState *pg = &state->pgraph;
    dma[3].limit = 16383;
    cpu_write(32768, 4096);
    for (unsigned stage = 0; stage < 2; stage++) {
        unsigned size = stage ? 16 : 8, levels = stage ? 5 : 1;
        NSUInteger offset = stage ? 2048 : 0, at = 0;
        for (unsigned level = 0; level < levels; level++) {
            unsigned n = MAX(1u, size >> level);
            for (unsigned y = 0; y < n; y++)
                for (unsigned x = 0; x < n; x++) {
                    unsigned r =
                        stage ? (17 + level * 43 + x * 11) % 256 : 7 + x * 31;
                    unsigned g =
                        stage ? (29 + level * 19 + y * 13) % 256 : 13 + y * 29;
                    unsigned b = stage ?
                                     (53 + level * 23 + x * 3 + y * 5) % 256 :
                                     9 + x * 17 + y * 5;
                    unsigned a = stage ? 255 : 64 + x * 13 + y * 11;
                    stl_le_p(state->vram_ptr + 32768 + offset + at +
                                 4 * pwg_morton(x, y),
                             a << 24 | r << 16 | g << 8 | b);
                }
            at += n * n * 4;
        }
        unsigned shift = stage ? 4 : 3;
        pg->regs_[NV_PGRAPH_TEXFMT0 + stage * 4] =
            NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8 << 8 | 2 << 6 |
            NV_PGRAPH_TEXFMT0_BORDER_SOURCE | levels << 16 | shift << 20 |
            shift << 24;
        pg->regs_[NV_PGRAPH_TEXOFFSET0 + stage * 4] = offset;
        pg->regs_[NV_PGRAPH_TEXCTL0_0 + stage * 4] =
            NV_PGRAPH_TEXCTL0_0_ENABLE | (stage ? 2u << 4 : 0) |
            (stage ? (4u << __builtin_ctz(NV_PGRAPH_TEXCTL0_0_MAX_LOD_CLAMP)) &
                         NV_PGRAPH_TEXCTL0_0_MAX_LOD_CLAMP :
                     0);
        /* Declaring five VRAM levels is insufficient when MAX_LOD_CLAMP
         * still selects zero: the real PGRAPH shape would contain one. */
        pg->regs_[NV_PGRAPH_TEXCTL1_0 + stage * 4] = 0;
        pg->regs_[NV_PGRAPH_TEXFILTER0 + stage * 4] =
            (stage ? 6u : 2u) << 16 | 2 << 24 | (stage ? 384 : 0);
        pg->regs_[NV_PGRAPH_TEXADDRESS0 + stage * 4] = 3 | 3 << 8 | 3 << 16;
        pg->texture_dirty[stage] = true;
    }
    pg->regs_[NV_PGRAPH_SHADERPROG] =
        PS_TEXTUREMODES_PROJECT2D | PS_TEXTUREMODES_DPNDNT_AR << 5;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG0] = PS_REGISTER_T1;
    pg->regs_[NV_PGRAPH_COMBINESPECFOG1] = (PS_REGISTER_T1 | PS_CHANNEL_ALPHA)
                                           << 8;
    pg->vertex_attributes[9] =
        (VertexAttribute){ .offset = 1024,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 4,
                           .stride = 16 };
    cpu_write(17408, 8 * 16);
    for (unsigned i = 0; i < 8; i++) {
        float position[4];
        memcpy(position, state->vram_ptr + 16384 + i * 16, 16);
        float uv[] = { position[0] * .5f - .5f, position[1] * .25f - .25f, 0,
                       1 };
        memcpy(state->vram_ptr + 17408 + i * 16, uv, 16);
    }
    /* These real RO outputs feed both sampling stages. No inline/uniform
     * substitute or synthetic texture binding enters the production caller. */
    mov(0, 0, 0, false);
    mov(1, 3, 3, false);
    mov(2, 7, 7, false);
    mov(3, 9, 9, true);
}
static void pwg_scene(unsigned kind)
{
    NSError *error = nil;
    qemu_mutex_lock(&state->pgraph.lock);
    require([draw closeWithError:&error], error);
    qemu_mutex_unlock(&state->pgraph.lock);
    draw = nil;
    surfaces = [[NV2AMetalPGRAPHSurfaces alloc] initWithState:state
                                                        error:&error];
    draw = [[NV2AMetalPGRAPHDraw alloc] initWithState:state
                                             surfaces:surfaces
                                                error:&error];
    require(surfaces && draw, error);
    unsigned program = kind == 0 ? 0 : kind == 4 ? 2 : 1;
    cff_scene(0, 0, program, YES, 13, YES);
    PGRAPHState *pg = &state->pgraph;
    pg->regs_[NV_PGRAPH_SETUPRASTER] &=
        ~(NV_PGRAPH_SETUPRASTER_CULLENABLE | (3u << 21));
    pg->surface_scale_factor = kind == 6 ? 2 : 1;
    pg->surface_shape.anti_aliasing =
        kind == 6 ? NV097_SET_SURFACE_FORMAT_ANTI_ALIASING_SQUARE_OFFSET_4 : 0;
    pg->regs_[NV_PGRAPH_CONTROL_3] |= NV_PGRAPH_CONTROL_3_SHADEMODE;
    if (kind == 5)
        pg->regs_[NV_PGRAPH_CONTROL_3] &= ~NV_PGRAPH_CONTROL_3_SHADEMODE;
    dma[2].limit = 4095;
    pg->dma_report = 80;
    BOOL exclusive = kind == 1 || kind == 3;
    if (exclusive)
        pg->regs_[NV_PGRAPH_SETUPRASTER] |=
            NV_PGRAPH_SETUPRASTER_WINDOWCLIPTYPE;
    else
        pg->regs_[NV_PGRAPH_SETUPRASTER] &=
            ~NV_PGRAPH_SETUPRASTER_WINDOWCLIPTYPE;
    for (unsigned i = 0; i < 8; i++)
        pg->regs_[NV_PGRAPH_WINDOWCLIPX0 + i * 4] =
            pg->regs_[NV_PGRAPH_WINDOWCLIPY0 + i * 4] = 1; /* Empty [1,1). */
    if (kind != 4) {
        pg->regs_[NV_PGRAPH_WINDOWCLIPX0] = kind == 5 ? 7u << 16 : 1 | 4u << 16;
        pg->regs_[NV_PGRAPH_WINDOWCLIPY0] = kind == 5 ? 7u << 16 : 1 | 5u << 16;
    }
    unsigned width = kind == 6 ? 16 : 8;
    pg->surface_color.pitch = pg->surface_zeta.pitch = width * 4;
    cpu_write(1024, width * width * 4);
    cpu_write(4096, width * width * 4);
    for (unsigned i = 0; i < width * width; i++) {
        stl_le_p(state->vram_ptr + 1024 + i * 4, UINT32_C(0xffff0000));
        stl_le_p(state->vram_ptr + 4096 + i * 4, UINT32_C(0xffffff11));
    }
    if (kind == 2 || kind == 3 || kind == 6 || kind == 7)
        pwg_textures();
}

static NSData *pwg_frame(unsigned kind, uint32_t *samples)
{
    NSError *error = nil;
    require([draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error],
            error);
    *samples = report_value(0);
    PGRAPHState *pg = &state->pgraph;
    NSUInteger length = kind == 6 ? 1024 : 256;
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, length);
    read_vram(4096, length);
    qemu_mutex_lock(&pg->lock);
    NSMutableData *data = [cpw_capture(*samples) mutableCopy];
    [data appendBytes:state->vram_ptr + 1024 length:length];
    [data appendBytes:state->vram_ptr + 4096 length:length];
    return data;
}
static NSData *pwg_run(unsigned kind, BOOL reference, BOOL anisotropyOne,
                       unsigned *pipelines, unsigned *compact,
                       unsigned *sampling, NSDictionary **observation)
{
    pwg_scene(kind);
    if (anisotropyOne) {
        assert(kind == 2);
        state->pgraph.regs_[NV_PGRAPH_TEXCTL0_0 + 4] &=
            ~NV_PGRAPH_TEXCTL0_0_MAX_ANISOTROPY;
    }
    pwg_reference = reference;
    pwg_pipelines = pwg_compact = pwg_sampling = 0;
    pwg_mip_count = 0;
    pwg_last_sampling = (NV2AMetalSamplingUniforms){ 0 };
    pwg_scope = YES;
    NSError *error = nil;
    PGRAPHState *pg = &state->pgraph;
    NSMutableData *actual = [NSMutableData new];
    qemu_mutex_lock(&pg->lock);
    if (kind == 7) {
        pg->inline_elements_length = 5;
        require([draw beginWithError:&error] &&
                    [draw prepareVertexStateChangeWithError:&error],
                error);
        NSData *pending = [draw pendingSnapshotWithError:&error];
        NSData *begin = [draw beginSnapshotWithError:&error];
        NSData *vertex = draw.vertexSnapshot;
        require(pending && begin && vertex, error);
        [actual appendData:pending];
        [actual appendData:begin];
        [actual appendData:vertex];
        require([draw discardForRestoreWithError:&error] &&
                    [draw restoreVertexSnapshot:vertex error:&error] &&
                    [draw restoreBeginSnapshot:begin error:&error] &&
                    [draw restorePendingSnapshot:pending error:&error] &&
                    [draw beginWithError:&error],
                error);
        pg->inline_elements_length = 13;
        NSData *host = fpp_host();
        pwg_fail_emit = YES;
        assert(![draw endWithError:&error] && error == pwg_failure &&
               !pwg_fail_emit && [host isEqualToData:fpp_host()]);
        error = nil;
        NSData *failed = [draw pendingSnapshotWithError:&error];
        require(failed != nil, error);
        [actual appendData:failed];
        require([draw endWithError:&error], error);
    } else {
        require([draw beginWithError:&error], error);
        NSData *begin = [draw beginSnapshotWithError:&error];
        NSData *pending = [draw pendingSnapshotWithError:&error];
        NSData *vertex = draw.vertexSnapshot;
        require(begin && pending && vertex, error);
        [actual appendData:begin];
        [actual appendData:pending];
        [actual appendData:vertex];
        require([draw endWithError:&error], error);
    }
    uint32_t query = 0;
    [actual appendData:pwg_frame(kind, &query)];
    /* Real PGRAPH register windows also preserve every clipped guest pixel.
     * The optimized source and reference see identical production scissor. */
    unsigned width = kind == 6 ? 16 : 8;
    uint32_t firstRGB = 0;
    BOOL colored = NO, varyingRGB = NO;
    for (unsigned y = 0; y < width; y++)
        for (unsigned x = 0; x < width; x++) {
            unsigned gx = kind == 6 ? x / 2 : x, gy = kind == 6 ? y / 2 : y;
            BOOL contained =
                kind == 5 || (gx >= 1 && gx < 5 && gy >= 1 && gy < 6);
            BOOL clipped = kind == 4 ||
                           ((kind == 1 || kind == 3) ? contained : !contained);
            if (clipped) {
                assert((uint32_t)ldl_le_p(state->vram_ptr + 1024 +
                                          (y * width + x) * 4) ==
                       UINT32_C(0xffff0000));
                assert((uint32_t)ldl_le_p(state->vram_ptr + 4096 +
                                          (y * width + x) * 4) ==
                       UINT32_C(0xffffff11));
            } else {
                uint32_t word = (uint32_t)ldl_le_p(state->vram_ptr + 1024 +
                                                   (y * width + x) * 4);
                if (word != UINT32_C(0xffff0000)) {
                    uint32_t rgb = word & UINT32_C(0x00ffffff);
                    if (colored)
                        varyingRGB |= rgb != firstRGB;
                    else
                        firstRGB = rgb;
                    colored = YES;
                }
            }
        }
    if (kind == 4) {
        assert(!query);
        expect_context(191, 15, 13, YES);
    } else
        assert(query);
    if (kind == 2 || kind == 3 || kind == 6 || kind == 7)
        assert(colored && varyingRGB); /* Real nonconstant dependent output. */
    assert(pg->draw_time == 1);
    if (observation) {
        /* cpw_capture starts with the two 256-byte guest attachments, then
         * contains every Current word, all constants/dirty flags, compressed
         * and inline-populated state and the exact query word. */
        NSData *captured = cpw_capture(query);
        assert(kind == 2 && captured.length > 512);
        *observation = @{
            @"color" : [NSData dataWithBytes:state->vram_ptr + 1024 length:256],
            @"zeta" : [NSData dataWithBytes:state->vram_ptr + 4096 length:256],
            @"draw_time" : @(pg->draw_time),
            @"mips" : @(pwg_mip_count),
            @"min_lod" : @(GET_MASK(pg->regs_[NV_PGRAPH_TEXCTL0_0 + 4],
                                    NV_PGRAPH_TEXCTL0_0_MIN_LOD_CLAMP)),
            @"max_lod" : @(GET_MASK(pg->regs_[NV_PGRAPH_TEXCTL0_0 + 4],
                                    NV_PGRAPH_TEXCTL0_0_MAX_LOD_CLAMP)),
            @"sampling" : [NSData dataWithBytes:&pwg_last_sampling
                                         length:sizeof(pwg_last_sampling)],
            @"state" : [captured
                subdataWithRange:NSMakeRange(512, captured.length - 512)]
        };
    }
    *pipelines = pwg_pipelines;
    *compact = pwg_compact;
    *sampling = pwg_sampling;
    pwg_scope = NO;
    qemu_mutex_unlock(&pg->lock);
    return actual;
}

static void pwg_difference(const char *field, NSData *a, NSData *b)
{
    NSUInteger offset = 0, count = MIN(a.length, b.length);
    const uint8_t *left = a.bytes, *right = b.bytes;
    while (offset < count && left[offset] == right[offset])
        offset++;
    if (offset < count || a.length != b.length)
        fprintf(stderr,
                "Window AF %s firstByte%zu af4=%d af1=%d lengths%zu/%zu\n",
                field, offset, offset < a.length ? left[offset] : -1,
                offset < b.length ? right[offset] : -1, a.length, b.length);
}

static void polygon_window_clip_pgraph_tests(void)
{
    /* Source helper is owned by the native test. The reference is a complete
     * exact inverse of this one optimization, without forcing gradients. */
    NSError *error = nil;
    id<MTL4Compiler> compiler = [surfaces.cache.commands.device
        newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                            error:&error];
    require(compiler != nil, error);
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = polygon_window_source(@(pwg_production_source), 1);
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    ld.options.mathMode = MTLMathModeSafe;
    ld.options.mathFloatingPointFunctions =
        MTLMathFloatingPointFunctionsPrecise;
    pwg_old_library = [compiler newLibraryWithDescriptor:ld error:&error];
    require(pwg_old_library != nil, error);
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalPixelShader.class,
            NSSelectorFromString(
                @"newPipelineForTopology:drawState:postprocess:fragmentKey:"
                @"rasterClass:error:")),
        class_getInstanceMethod(
            NV2AMetalPixelShader.class,
            @selector(
                prepareGeometry:offset:count:uniforms:textures:pass:drawState:
                rasterClass:ignorePolygonCulling:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:))
    };
    IMP replacements[] = { (IMP)pwg_pipeline, (IMP)pwg_prepare, (IMP)pwg_emit },
        originals[3];
    for (unsigned i = 0; i < 3; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    pwg_pipeline_original = (void *)originals[0];
    pwg_prepare_original = (void *)originals[1];
    pwg_emit_original = (void *)originals[2];
    pwg_failure = [NSError errorWithDomain:@"test.polygon-window-clip.emit"
                                      code:1
                                  userInfo:nil];
    for (unsigned i = 0; i < 3; i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        for (unsigned kind = 0; kind < 8; kind++)
            @autoreleasepool {
                unsigned pipelines[2], compact[2], sampling[2];
                NSDictionary *af4 = nil;
                NSData *old = pwg_run(kind, YES, NO, &pipelines[0], &compact[0],
                                      &sampling[0], NULL);
                NSData *actual =
                    pwg_run(kind, NO, NO, &pipelines[1], &compact[1],
                            &sampling[1], kind == 2 ? &af4 : NULL);
                if (![old isEqualToData:actual])
                    fprintf(stderr,
                            "Polygon window PGRAPH group%u exact "
                            "GPU/state/wire mismatch\n",
                            kind);
                assert([old isEqualToData:actual]);
                assert(pipelines[0] && !pipelines[1] && compact[0] &&
                       compact[1]);
                if (kind == 2 || kind == 3 || kind == 6 || kind == 7)
                    assert(sampling[0] && sampling[1]);
                if (kind == 2) {
                    NSDictionary *af1 = nil;
                    unsigned controlPipelines, controlCompact, controlSampling;
                    (void)pwg_run(kind, NO, YES, &controlPipelines,
                                  &controlCompact, &controlSampling, &af1);
                    NSData *four = af4[@"color"], *one = af1[@"color"];
                    assert(four.length == 256 && one.length == 256);
                    BOOL differentRGB = NO;
                    for (unsigned i = 0; i < 64; i++) {
                        uint32_t a, b;
                        memcpy(&a, (const uint8_t *)four.bytes + i * 4, 4);
                        memcpy(&b, (const uint8_t *)one.bytes + i * 4, 4);
                        differentRGB |= ((a ^ b) & UINT32_C(0x00ffffff)) != 0;
                    }
                    /* A real register-only AF1 control must discriminate the
                     * actual fragment output; this is not a shader tap count
                     * or a timing claim. All other guest results stay exact. */
                    if (!(differentRGB && ![four isEqualToData:one] &&
                          [af4[@"zeta"] isEqualToData:af1[@"zeta"]] &&
                          [af4[@"state"] isEqualToData:af1[@"state"]])) {
                        uint32_t queries[2] = { 0 };
                        NV2AMetalSamplingUniforms policies[2] = { 0 };
                        NSDictionary *observed[] = { af4, af1 };
                        for (unsigned i = 0; i < 2; i++) {
                            NSData *s = observed[i][@"state"],
                                   *p = observed[i][@"sampling"];
                            assert(s.length >= 4 &&
                                   p.length == sizeof(policies[i]));
                            memcpy(&queries[i],
                                   (const uint8_t *)s.bytes + s.length - 4, 4);
                            memcpy(&policies[i], p.bytes, sizeof(policies[i]));
                        }
                        fprintf(stderr,
                                "Window AF control differentRGB%d "
                                "framebufferEqual%d "
                                "zetaEqual%d stateEqual%d query%u/%u time%d/%d "
                                "mips%lu/%lu clampMin%u/%u clampMax%u/%u "
                                "sampling(enabled,min,mag,mip,AF,bias) "
                                "%u,%u,%u,%u,%u,%.9g / %u,%u,%u,%u,%u,%.9g\n",
                                differentRGB, [four isEqualToData:one],
                                [af4[@"zeta"] isEqualToData:af1[@"zeta"]],
                                [af4[@"state"] isEqualToData:af1[@"state"]],
                                queries[0], queries[1],
                                [af4[@"draw_time"] intValue],
                                [af1[@"draw_time"] intValue],
                                [af4[@"mips"] unsignedLongValue],
                                [af1[@"mips"] unsignedLongValue],
                                [af4[@"min_lod"] unsignedIntValue],
                                [af1[@"min_lod"] unsignedIntValue],
                                [af4[@"max_lod"] unsignedIntValue],
                                [af1[@"max_lod"] unsignedIntValue],
                                policies[0].enabled, policies[0].min_linear,
                                policies[0].mag_linear, policies[0].mip_filter,
                                policies[0].anisotropy,
                                (double)policies[0].lod_bias,
                                policies[1].enabled, policies[1].min_linear,
                                policies[1].mag_linear, policies[1].mip_filter,
                                policies[1].anisotropy,
                                (double)policies[1].lod_bias);
                        pwg_difference("color", four, one);
                        pwg_difference("zeta", af4[@"zeta"], af1[@"zeta"]);
                        pwg_difference("state", af4[@"state"], af1[@"state"]);
                    }
                    assert(differentRGB && ![four isEqualToData:one] &&
                           [af4[@"zeta"] isEqualToData:af1[@"zeta"]] &&
                           [af4[@"state"] isEqualToData:af1[@"state"]]);
                    assert(!controlPipelines && controlCompact &&
                           !controlSampling &&
                           [af1[@"mips"] unsignedIntegerValue] == 5);
                    NV2AMetalSamplingUniforms controlPolicy;
                    NSData *policy = af1[@"sampling"];
                    assert(policy.length == sizeof(controlPolicy));
                    memcpy(&controlPolicy, policy.bytes, sizeof(controlPolicy));
                    assert(controlPolicy.enabled == 1 &&
                           controlPolicy.min_linear == 1 &&
                           controlPolicy.mag_linear == 1 &&
                           controlPolicy.mip_filter == 2 &&
                           controlPolicy.anisotropy == 1 &&
                           controlPolicy.lod_bias == 1.5f &&
                           [af1[@"min_lod"] unsignedIntValue] == 0 &&
                           [af1[@"max_lod"] unsignedIntValue] == 4);
                }
            }
    } @finally {
        for (unsigned i = 0; i < 3; i++)
            method_setImplementation(methods[i], originals[i]);
        pwg_scope = pwg_reference = pwg_fail_emit = NO;
        pwg_old_library = nil;
        pwg_failure = nil;
    }
    groups += 8;
    puts("Polygon window PGRAPH:8 exact old-source "
         "framebuffer/Zeta/query/Current/"
         "constant/archive pairs; odd inclusive/exclusive, real varying T0->AR "
         "Mip/AF with discriminating register-only AF1 control, writer-zero, "
         "Flat/TwoSide, NV-AA4/Scale2, "
         "Prefix/Restore/lateRetry PASS");
}
#endif
