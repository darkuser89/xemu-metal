/* Real texture-cache hits, cancellation, immutable bindings and mip views.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_TEXTURE_HIT_CACHE_H
#define TEST_METAL_TEXTURE_HIT_CACHE_H
#import "hw/xbox/nv2a/pgraph/metal/lru-cache.h"
#include <time.h>

static IMP hit_saved_cancelled, hit_saved_binding;
static NSUInteger hit_cancel_reads, hit_binding_calls;
static BOOL hit_count_cancelled(id object, SEL selector)
{
    hit_cancel_reads++;
    return ((BOOL (*)(id, SEL))hit_saved_cancelled)(object, selector);
}
static id hit_count_binding(id object, SEL selector, id texture,
                            const NV2AMetalSamplerConfig *config,
                            NSError **error)
{
    hit_binding_calls++;
    return ((id (*)(id, SEL, id, const NV2AMetalSamplerConfig *,
                    NSError **))hit_saved_binding)(object, selector, texture,
                                                   config, error);
}
static double hit_clock(void)
{
    struct timespec t;
    assert(!clock_gettime(CLOCK_MONOTONIC, &t));
    return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
}
static int hit_compare(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static NV2AMetalCachedTexture *hit_prepare(NV2AMetalTextureSource source,
                                           NV2AMetalSamplerConfig sampler)
{
    NSError *error = nil;
    NV2AMetalCachedTexture *t = [textures prepareSource:&source
                                                sampler:&sampler
                                                  frame:1
                                                  error:&error];
    require(t != nil, error);
    return t;
}

static void texture_hit_cache_tests(void)
{
    NSError *error = nil;
    Method cancelled = class_getInstanceMethod(NV2AMetalSurfaceRecording.class,
                                               @selector(cancelled));
    Method binding =
        class_getInstanceMethod(NV2AMetalTextureSampler.class,
                                @selector(bindingForTexture:config:error:));
    assert(cancelled && binding);
    hit_saved_cancelled =
        method_setImplementation(cancelled, (IMP)hit_count_cancelled);
    hit_saved_binding =
        method_setImplementation(binding, (IMP)hit_count_binding);
    /* Real prepareSource timings include source versions, page/overlap checks,
     * key/result allocation, validation and residency, not just the LRU. */
    for (unsigned size = 1; size <= 512; size = size == 1   ? 16 :
                                                size == 16  ? 128 :
                                                size == 128 ? 512 :
                                                              513) {
        [textures removeAllTextures];
        cpu_write(65536, 513 * 64);
        uint32_t *pixels =
            (uint32_t *)((uint8_t *)surfaces.vram.contents + 65536);
        for (unsigned p = 0; p < 513 * 16; p++)
            pixels[p] = 0xff030201;
        NV2AMetalCachedTexture *hot = nil;
        NV2AMetalTextureSource src = source(
            65536, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, 16);
        for (unsigned i = 0; i < size; i++) {
            NV2AMetalTextureSource c = src;
            c.address += i * 64;
            NV2AMetalCachedTexture *t = prepare(c);
            if (!i)
                hot = t;
        }
        finish();
        require([hot validateCompletedWithError:&error], error);
        assert(textures.count == size);
        double times[7];
        NSUInteger reads = 0;
        for (unsigned sample = 0; sample < 9; sample++) {
            hit_cancel_reads = hit_binding_calls = 0;
            double start = hit_clock();
            for (unsigned n = 0; n < 128; n++) {
                @autoreleasepool {
                    NV2AMetalCachedTexture *t = prepare(src);
                    assert(t.binding == hot.binding);
                }
            }
            double ms = hit_clock() - start;
            assert(!hit_binding_calls && hit_cancel_reads <= 4 * 128);
            reads = hit_cancel_reads;
            if (sample >= 2)
                times[sample - 2] = ms;
            finish();
        }
        qsort(times, 7, sizeof(times[0]), hit_compare);
        id<MTLBuffer> out = read_texture(prepare(src));
        finish();
        color_at(out, 4, 0, 0, 3.f / 255, 2.f / 255, 1.f / 255, 1);

        /* Isolate the former cancellation sweep + ordered-set promotion using
         * the same real content objects and keys. This is not an old binary or
         * an end-to-end before/after comparison. */
        NV2AMetalLRUCache *lru = [textures valueForKey:@"entries"];
        NSDictionary *nodes = [lru valueForKey:@"entries"];
        NSMutableDictionary *legacy = [NSMutableDictionary new];
        NSMutableOrderedSet *order = [NSMutableOrderedSet new];
        id hotKey = nil;
        for (id key in nodes) {
            id content = [nodes[key] valueForKey:@"object"];
            legacy[key] = content;
            [order addObject:key];
            if ([content valueForKey:@"texture"] == hot.binding.texture)
                hotKey = key;
        }
        assert(hotKey && legacy.count == size);
        hit_cancel_reads = 0;
        for (unsigned n = 0; n < 128; n++) {
            for (id key in [order.array copy]) {
                NV2AMetalSurfaceRecording *token =
                    [legacy[key] valueForKey:@"token"];
                assert(!token.cancelled);
            }
            id content = legacy[hotKey];
            assert(content);
            [order removeObject:hotKey];
            [order addObject:hotKey];
        }
        assert(hit_cancel_reads == 128 * size);
        printf("Texture hits size=%u: 128 complete prepareSource calls median "
               "%.6f ms "
               "(2 warmups/7 samples), %lu cancellation reads, zero "
               "binding/view creations; "
               "isolated old sweep %lu reads/128 array copies\n",
               size, times[3], (unsigned long)reads,
               (unsigned long)hit_cancel_reads);
    }

    [textures removeAllTextures];
    NV2AMetalTextureSource stableSource =
        source(65536, NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8, 4, 16);
    NV2AMetalCachedTexture *stable = prepare(stableSource);
    finish();
    NSMutableArray<NV2AMetalCachedTexture *> *aborted = [NSMutableArray new];
    for (unsigned i = 0; i < 32; i++) {
        NV2AMetalTextureSource c = stableSource;
        c.address += (i + 1) * 64;
        [aborted addObject:prepare(c)];
    }
    [surfaces cancel];
    NV2AMetalCachedTexture *same = prepare(stableSource);
    assert(same.binding == stable.binding);
    finish();
    for (unsigned i = 0; i < 32; i++) {
        assert(![aborted[i] validateCompletedWithError:&error]);
        NV2AMetalTextureSource c = stableSource;
        c.address += (i + 1) * 64;
        NV2AMetalCachedTexture *retry = prepare(c);
        assert(retry.binding.texture != aborted[i].binding.texture);
        id<MTLBuffer> out = read_texture(retry);
        finish();
        require([retry validateCompletedWithError:&error], error);
        color_at(out, 4, 0, 0, 3.f / 255, 2.f / 255, 1.f / 255, 1);
    }
    assert(textures.count == 33);
    /* Failures in a changed policy cancel and remove the matched entry. The
     * previously captured completed binding remains valid and immutable. */
    NV2AMetalSamplerConfig invalid = policy();
    invalid.anisotropy = 3;
    assert(![textures prepareSource:&stableSource
                            sampler:&invalid
                              frame:1
                              error:&error]);
    require([stable validateCompletedWithError:&error], error);
    assert(prepare(stableSource).binding.texture != stable.binding.texture);
    finish();

    NV2AMetalTextureSource mip = {
        .address = 32768,
        .shape = { .format = NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8,
                   .dimension = 2,
                   .width = 8,
                   .height = 8,
                   .depth = 1,
                   .levels = 4,
                   .min_level = 1,
                   .max_level = 2 }
    };
    require([textures sourceLengthForShape:&mip.shape
                             paletteLength:0
                                    length:&mip.length
                                     error:&error],
            error);
    cpu_write(mip.address, mip.length);
    uint32_t *data =
        (uint32_t *)((uint8_t *)surfaces.vram.contents + mip.address);
    for (unsigned i = 0; i < mip.length / 4; i++)
        data[i] = 0xff030201;
    NV2AMetalSamplerConfig p = policy();
    NV2AMetalCachedTexture *initial = hit_prepare(mip, p);
    finish();
    assert(initial.binding.texture.width == 4 &&
           initial.binding.texture.mipmapLevelCount == 2);
    hit_binding_calls = 0;
    for (unsigned i = 0; i < 64; i++) {
        /* Different struct padding must not prevent semantic equality. */
        NV2AMetalSamplerConfig padded;
        memset(&padded, i, sizeof(padded));
        padded.filter = p.filter;
        padded.address = p.address;
        padded.border_color = p.border_color;
        padded.anisotropy = p.anisotropy;
        padded.min_level = p.min_level;
        padded.max_level = p.max_level;
        padded.rectangle = p.rectangle;
        padded.bordered = p.bordered;
        padded.hilo16 = p.hilo16;
        padded.signed_channels = p.signed_channels;
        assert(hit_prepare(mip, padded).binding == initial.binding);
    }
    assert(!hit_binding_calls);
    finish();
    NV2AMetalSamplingUniforms original = initial.binding.sampling;
    for (unsigned field = 0; field < 4; field++) {
        NV2AMetalSamplerConfig changed = p;
        if (field == 0)
            changed.filter = 2 << 16 | 2 << 24;
        if (field == 1)
            changed.address = 2 | 3 << 8 | 3 << 16;
        if (field == 2)
            changed.border_color = 0x12345678;
        if (field == 3)
            changed.anisotropy = 2;
        hit_binding_calls = 0;
        NV2AMetalCachedTexture *next = hit_prepare(mip, changed);
        assert(next.binding != initial.binding && hit_binding_calls == 1);
        assert(hit_prepare(mip, changed).binding == next.binding &&
               hit_binding_calls == 1);
        NV2AMetalSamplingUniforms old = initial.binding.sampling;
        assert(!memcmp(&old, &original, sizeof(old)));
        id<MTLBuffer> out = read_texture(next);
        finish();
        color_at(out, 4, 0, 0, 3.f / 255, 2.f / 255, 1.f / 255, 1);
    }
    cpu_write(mip.address, mip.length);
    for (unsigned i = 0; i < mip.length / 4; i++)
        data[i] = 0xff060504;
    NV2AMetalCachedTexture *fresh = hit_prepare(mip, p);
    assert(fresh.binding.texture != initial.binding.texture);
    id<MTLBuffer> before = read_texture(initial), after = read_texture(fresh);
    finish();
    color_at(before, 4, 0, 0, 3.f / 255, 2.f / 255, 1.f / 255, 1);
    color_at(after, 4, 0, 0, 6.f / 255, 5.f / 255, 4.f / 255, 1);
    method_setImplementation(cancelled, hit_saved_cancelled);
    method_setImplementation(binding, hit_saved_binding);
    [textures removeAllTextures];
    puts("Texture hit cache: 32 cancelled retries, completed snapshot "
         "isolation, "
         "invalid policy removal, 64 identical mip bindings, four changed "
         "policies, "
         "CPU-write old/new mip pixels PASS; no app");
}
#endif
