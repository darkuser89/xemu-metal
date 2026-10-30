/* Direct binding validation, portable parity and live layout invalidation.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_BINDING_STRUCT_H
#define TEST_METAL_BINDING_STRUCT_H
#import <objc/runtime.h>
#import "hw/xbox/nv2a/pgraph/metal/pixel-pgraph.h"
#include <time.h>
static IMP binding_original_evict;
static unsigned binding_evicts, binding_change_scale = UINT_MAX;
static BOOL binding_evict(id owner, SEL selector, uint32_t frame,
                          NSError **error)
{
    BOOL ok = ((BOOL (*)(id, SEL, uint32_t, NSError **))binding_original_evict)(
        owner, selector, frame, error);
    if (owner == surfaces.cache) {
        binding_evicts++;
        if (binding_change_scale != UINT_MAX) {
            state->pgraph.surface_scale_factor = binding_change_scale;
            binding_change_scale = UINT_MAX;
        }
    }
    return ok;
}
static double binding_clock(void)
{
    struct timespec t;
    assert(!clock_gettime(CLOCK_MONOTONIC, &t));
    return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
}
static int binding_compare(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static NV2AMetalSurfaceBindings binding_fixture(void)
{
    return (NV2AMetalSurfaceBindings){
        .color = { .config = { .format =
                                   NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
                               .width = 8,
                               .height = 8,
                               .pitch = 32,
                               .scale = 1,
                               .color = YES },
                   .address = 1024 },
        .zeta = { .config = { .format = NV097_SET_SURFACE_FORMAT_ZETA_Z16,
                              .width = 8,
                              .height = 8,
                              .pitch = 16,
                              .scale = 1 },
                  .address = 4096 }
    };
}
static void binding_begin_clear_tests(void)
{
    const uint32_t parameters[] = { NV097_CLEAR_SURFACE_R,
                                    NV097_CLEAR_SURFACE_G,
                                    NV097_CLEAR_SURFACE_B,
                                    NV097_CLEAR_SURFACE_A,
                                    NV097_CLEAR_SURFACE_COLOR,
                                    NV097_CLEAR_SURFACE_Z,
                                    NV097_CLEAR_SURFACE_STENCIL,
                                    NV097_CLEAR_SURFACE_COLOR |
                                        NV097_CLEAR_SURFACE_Z |
                                        NV097_CLEAR_SURFACE_STENCIL };
    unsigned pairs = 0;
    for (unsigned dither = 0; dither < 2; dither++)
        for (unsigned kind = 0; kind < G_N_ELEMENTS(parameters); kind++) {
            NSData *images[2];
            for (unsigned mode = 0; mode < 2; mode++) {
                fixture();
                PGRAPHState *pg = &state->pgraph;
                pg->surface_shape.zeta_format =
                    NV097_SET_SURFACE_FORMAT_ZETA_Z24S8;
                pg->surface_zeta.pitch = 32;
                pg->regs_[NV_PGRAPH_COLORCLEARVALUE] = 0x80336699;
                pg->regs_[NV_PGRAPH_ZSTENCILCLEARVALUE] = 0x8080807f;
                pg->regs_[NV_PGRAPH_CLEARRECTX] =
                    pg->regs_[NV_PGRAPH_CLEARRECTY] = 7u << 16;
                qemu_mutex_lock(&pg->lock);
                NSError *error = nil;
                require([draw beginWithError:&error], error);
                NV2AMetalPGRAPHPixelState *before =
                    [draw valueForKey:@"pixelState"];
                NSData *original = before.snapshotData;
                if (dither)
                    pg->regs_[NV_PGRAPH_CONTROL_0] |=
                        NV_PGRAPH_CONTROL_0_DITHERENABLE;
                uint32_t parameter = parameters[kind];
                NV2AMetalDrawConfig c = before.raster.config;
                if (parameter & NV097_CLEAR_SURFACE_COLOR) {
                    const uint32_t bits[] = {
                        NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE,
                        NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE,
                        NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE,
                        NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE
                    };
                    const uint32_t masks[] = { NV097_CLEAR_SURFACE_R,
                                               NV097_CLEAR_SURFACE_G,
                                               NV097_CLEAR_SURFACE_B,
                                               NV097_CLEAR_SURFACE_A };
                    for (unsigned k = 0; k < 4; k++) {
                        c.control[0] &= ~bits[k];
                        if (parameter & masks[k])
                            c.control[0] |= bits[k];
                    }
                }
                if (parameter & NV097_CLEAR_SURFACE_Z)
                    c.control[0] |= NV_PGRAPH_CONTROL_0_ZWRITEENABLE;
                if (parameter & NV097_CLEAR_SURFACE_STENCIL)
                    c.control[1] |= NV_PGRAPH_CONTROL_1_STENCIL_MASK_WRITE;
                c.control[0] =
                    (c.control[0] & ~NV_PGRAPH_CONTROL_0_DITHERENABLE) |
                    (pg->regs_[NV_PGRAPH_CONTROL_0] &
                     NV_PGRAPH_CONTROL_0_DITHERENABLE);
                NSMutableData *wire = [original mutableCopy];
                stl_be_p((uint8_t *)wire.mutableBytes + 7 * 4, 0);
                stl_be_p((uint8_t *)wire.mutableBytes + 8 * 4, c.control[0]);
                stl_be_p((uint8_t *)wire.mutableBytes + 9 * 4, c.control[1]);
                NV2AMetalPGRAPHPixelState *reference =
                    [[NV2AMetalPGRAPHPixelState alloc]
                        initWithSnapshot:wire
                                textures:before.textureSnapshot
                                  device:surfaces.cache.commands.device
                                   error:&error];
                require(reference != nil, error);
                require([draw clearSurface:parameter error:&error], error);
                NV2AMetalPGRAPHPixelState *actual =
                    [draw valueForKey:@"pixelState"];
                assert([actual.snapshotData isEqual:wire] &&
                       [before.snapshotData isEqual:original]);
                if (mode)
                    [draw setValue:reference forKey:@"pixelState"];
                require([draw endWithError:&error], error);
                qemu_mutex_unlock(&pg->lock);
                read_vram(1024, 256);
                read_vram(4096, 256);
                NSMutableData *pixels =
                    [NSMutableData dataWithBytes:state->vram_ptr + 1024
                                          length:256];
                [pixels appendBytes:state->vram_ptr + 4096 length:256];
                images[mode] = pixels;
            }
            assert([images[0] isEqual:images[1]]);
            pairs++;
        }
    fixture();
    printf("Typed Clear inside Begin: %u exact color+depth/stencil VRAM image "
           "pairs, "
           "persistent masks/dither and immutable captured state versus "
           "portable reference PASS\n",
           pairs);
}
static void binding_struct_tests(void)
{
    unsigned cases = 0, rejects = 0;
    NSError *error = nil;
    for (unsigned n = 0; n < 2048; n++) {
        NV2AMetalSurfaceBindings b = binding_fixture();
        unsigned w = 1u << ((n >> 2) % 6), h = 1u << ((n >> 5) % 6),
                 scale = 1 + n % 4;
        BOOL swizzle = (n >> 8) & 1;
        b.color.config.width = b.zeta.config.width = w;
        b.color.config.height = b.zeta.config.height = h;
        b.color.config.scale = b.zeta.config.scale = scale;
        b.color.config.swizzle = b.zeta.config.swizzle = swizzle;
        b.color.config.pitch = w * 4 + (n % 3) * 8;
        b.zeta.config.pitch = w * 2 + (n % 5) * 4;
        b.zeta.address = 0x04000000u + n * 256;
        if (!(n & 1))
            b.color.config.width = 0;
        if (!(n & 2))
            b.zeta.config.width = 0;
        require(nv2a_metal_surface_bindings_validate(b, &error), error);
        NSData *wire = nv2a_metal_surface_bindings_encode(b);
        NV2AMetalSurfaceBindings restored;
        require(nv2a_metal_surface_bindings_decode(wire, &restored, &error),
                error);
        assert([nv2a_metal_surface_bindings_encode(restored) isEqual:wire]);
        assert(wire.length == 68);
        cases++;
    }
    for (unsigned kind = 0; kind < 12; kind++) {
        NV2AMetalSurfaceBindings b = binding_fixture();
        if (kind == 0)
            b.zeta.config.width++;
        if (kind == 1)
            b.zeta.config.scale++;
        if (kind == 2)
            b.zeta.address = b.color.address;
        if (kind == 3)
            b.color.address = NSUIntegerMax;
        if (kind == 4)
            b.color.config.pitch = 0;
        if (kind == 5)
            b.color.config.scale = 0;
        if (kind == 6)
            b.color.config.format = 0;
        if (kind == 7) {
            b.color.config.swizzle = YES;
            b.color.config.width = 3;
        }
        if (kind == 8)
            b.color.address = 0x08000000u - 4;
        if (kind == 9)
            b.zeta.config.format = UINT_MAX;
        if (kind == 10)
            b.color.config.width = UINT_MAX;
        if (kind == 11)
            b.zeta.config.height = 0;
        error = nil;
        assert(!nv2a_metal_surface_bindings_validate(b, &error) && error);
        error = nil;
        assert(!nv2a_metal_surface_bindings_decode(
                   nv2a_metal_surface_bindings_encode(b), NULL, &error) &&
               error);
        rejects++;
    }
    /* Internal addresses must never be accepted through uint32 truncation. */
    NV2AMetalSurfaceBindings wide = binding_fixture();
    wide.color.address += UINT64_C(1) << 32;
    error = nil;
    assert(!nv2a_metal_surface_bindings_validate(wide, &error) && error);
    rejects++;
    /* Packet-specific absent/header checks remain external decode checks. */
    NSMutableData *bad =
        [nv2a_metal_surface_bindings_encode((NV2AMetalSurfaceBindings){ 0 })
            mutableCopy];
    stl_be_p((uint8_t *)bad.mutableBytes + 12, 1);
    error = nil;
    assert(!nv2a_metal_surface_bindings_decode(bad, NULL, &error) && error);
    rejects++;
    stl_be_p((uint8_t *)bad.mutableBytes + 12, 0);
    stl_be_p((uint8_t *)bad.mutableBytes + 4, 2);
    error = nil;
    assert(!nv2a_metal_surface_bindings_decode(bad, NULL, &error) && error);
    rejects++;
    bad = [nv2a_metal_surface_bindings_encode(binding_fixture()) mutableCopy];
    /* A present wire binding cannot use the internal absent-width sentinel. */
    stl_be_p((uint8_t *)bad.mutableBytes + 20, 0);
    error = nil;
    assert(!nv2a_metal_surface_bindings_decode(bad, NULL, &error) && error);
    rejects++;
    double times[2][7];
    NV2AMetalSurfaceBindings valid = binding_fixture();
    for (unsigned pair = 0; pair < 9; pair++)
        for (unsigned order = 0; order < 2; order++) {
            unsigned mode = (pair + order) & 1;
            double start = binding_clock();
            for (unsigned n = 0; n < 128; n++)
                @autoreleasepool {
                    error = nil;
                    BOOL ok =
                        mode ?
                            nv2a_metal_surface_bindings_decode(
                                nv2a_metal_surface_bindings_encode(valid), NULL,
                                &error) :
                            nv2a_metal_surface_bindings_validate(valid, &error);
                    require(ok, error);
                }
            double ms = binding_clock() - start;
            if (pair >= 2)
                times[mode][pair - 2] = ms;
        }
    for (unsigned mode = 0; mode < 2; mode++)
        qsort(times[mode], 7, sizeof(double), binding_compare);
    fixture();
    PGRAPHState *pg = &state->pgraph;
    qemu_mutex_lock(&pg->lock);
    require([surfaces prepareColor:YES zeta:YES error:&error], error);
    require([surfaces.cache flushWithError:&error], error);
    NV2AMetalSurfaceBindings saved = surfaces.captureBindings;
    Method method = class_getInstanceMethod(NV2AMetalSurfaceCache.class,
                                            @selector(evictBeforeFrame:error:));
    binding_original_evict =
        method_setImplementation(method, (IMP)binding_evict);
    NV2AMetalCachedSurface *oldColor = surfaces.color, *oldZeta = surfaces.zeta;
    NV2AMetalSurfaceBindings outside = saved;
    outside.color.address = 65535;
    binding_evicts = 0;
    error = nil;
    assert(![surfaces prepareBindings:outside error:&error] && error &&
           !binding_evicts);
    assert(surfaces.color == oldColor && surfaces.zeta == oldZeta);
    binding_change_scale = 2;
    binding_evicts = 0;
    error = nil;
    require([surfaces prepareBindings:saved error:&error], error);
    assert(binding_evicts == 1 && surfaces.color.transfer.config.scale == 2 &&
           surfaces.zeta.transfer.config.scale == 2);
    saved = surfaces.captureBindings;
    oldColor = surfaces.color;
    oldZeta = surfaces.zeta;
    require([surfaces.cache flushWithError:&error], error);
    binding_change_scale = 0;
    binding_evicts = 0;
    error = nil;
    assert(![surfaces prepareBindings:saved error:&error] && error &&
           binding_evicts == 1);
    assert(surfaces.color == oldColor && surfaces.zeta == oldZeta);
    method_setImplementation(method, binding_original_evict);
    binding_change_scale = UINT_MAX;
    pg->surface_scale_factor = 1;
    qemu_mutex_unlock(&pg->lock);
    fixture();
    binding_begin_clear_tests();
    printf("Typed bindings:%u valid direct/portable cases,%u invalid "
           "layouts/packets;"
           "VRAM-span rejection before eviction,live scale1->2 success/2->0 "
           "rejection "
           "across eviction with rollback PASS\n",
           cases, rejects);
    printf(
        "Typed bindings:128 validations median direct/portable %.6f/%.6f ms;"
        "0/128 logical68-byte packets,2 warmups/7 alternating pairs;no app\n",
        times[0][3], times[1][3]);
}
#endif
