/* M20 page-proof negatives skip only disjoint surface metadata scans.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SURFACE_NEGATIVE_GATE_H
#define TEST_METAL_SURFACE_NEGATIVE_GATE_H
@interface NV2AMetalSurfaceCache (SurfaceNegativeGateTest)
- (BOOL)surfaceTargetsMayOverlapAddress:(NSUInteger)address
                                 length:(NSUInteger)length;
- (BOOL)sourceVersionForValidatedSpan:(NV2AMetalVRAMReadSpan)span
                              version:(uint64_t *)version
                    containingSurface:(NV2AMetalCachedSurface **)surface
                                error:(NSError **)error;
- (BOOL)
    findDirtySurfacesForReadPatterns:(const NV2AMetalVRAMReadPattern *)patterns
                               count:(NSUInteger)count
                              bounds:(NSRange)bounds
                            selected:
                                (NSMutableArray<NV2AMetalCachedSurface *> **)
                                    selected;
@end
static __weak NV2AMetalSurfaceCache *sg_owner;
static _Thread_local unsigned sg_role;
static _Thread_local BOOL sg_reference;
static _Thread_local NSUInteger sg_getters[3], sg_calls[3], sg_yes[3], sg_no[3];
static BOOL (*sg_gate_original)(id, SEL, NSUInteger, NSUInteger);
static BOOL (*sg_source_original)(id, SEL, NV2AMetalVRAMReadSpan, uint64_t *,
                                  NV2AMetalCachedSurface **, NSError **);
static BOOL (*sg_dirty_original)(id, SEL, const NV2AMetalVRAMReadPattern *,
                                 NSUInteger, NSRange, NSMutableArray **);
static NSUInteger (*sg_address_original)(id, SEL),
    (*sg_length_original)(id, SEL);
static uint64_t (*sg_generation_original)(id, SEL);
static BOOL (*sg_surface_dirty_original)(id, SEL);
static BOOL sg_gate(id object, SEL selector, NSUInteger address,
                    NSUInteger length)
{
    BOOL observed = object == sg_owner && sg_role;
    BOOL result = observed && sg_reference ?
                      YES :
                      sg_gate_original(object, selector, address, length);
    if (observed) {
        sg_calls[sg_role]++;
        if (result)
            sg_yes[sg_role]++;
        else
            sg_no[sg_role]++;
    }
    return result;
}
static BOOL sg_source(id object, SEL selector, NV2AMetalVRAMReadSpan span,
                      uint64_t *version, NV2AMetalCachedSurface **surface,
                      NSError **error)
{
    unsigned saved = sg_role;
    if (object == sg_owner)
        sg_role = 1;
    @try {
        return sg_source_original(object, selector, span, version, surface,
                                  error);
    } @finally {
        sg_role = saved;
    }
}
static BOOL sg_dirty(id object, SEL selector,
                     const NV2AMetalVRAMReadPattern *patterns, NSUInteger count,
                     NSRange bounds, NSMutableArray **selected)
{
    unsigned saved = sg_role;
    if (object == sg_owner)
        sg_role = 2;
    @try {
        return sg_dirty_original(object, selector, patterns, count, bounds,
                                 selected);
    } @finally {
        sg_role = saved;
    }
}
static NSUInteger sg_address(id object, SEL selector)
{
    if (sg_role)
        sg_getters[sg_role]++;
    return sg_address_original(object, selector);
}
static NSUInteger sg_length(id object, SEL selector)
{
    if (sg_role)
        sg_getters[sg_role]++;
    return sg_length_original(object, selector);
}
static uint64_t sg_generation(id object, SEL selector)
{
    if (sg_role)
        sg_getters[sg_role]++;
    return sg_generation_original(object, selector);
}
static BOOL sg_surface_dirty(id object, SEL selector)
{
    if (sg_role)
        sg_getters[sg_role]++;
    return sg_surface_dirty_original(object, selector);
}
static void sg_reset(void)
{
    memset(sg_getters, 0, sizeof(sg_getters));
    memset(sg_calls, 0, sizeof(sg_calls));
    memset(sg_yes, 0, sizeof(sg_yes));
    memset(sg_no, 0, sizeof(sg_no));
}
static id<MTLBuffer> sg_copy(NV2AMetalSurfaceCache *cache,
                             NV2AMetalVRAMReadPattern p)
{
    NSError *error = nil;
    require([cache prepareGPUReadPattern:p error:&error], error);
    NSUInteger elements = p.stride ? (p.length - p.element) / p.stride + 1 : 1;
    NSUInteger bytes = p.stride ? p.element : p.length;
    id<MTLBuffer> output = [cache.commands.device
        newBufferWithLength:elements * bytes
                    options:MTLResourceStorageModeShared];
    assert(output);
    memset(output.contents, 0xcd, output.length);
    require([cache.commands addResource:output error:&error] &&
                [cache.commands addResource:cache.vram error:&error],
            error);
    id<MTL4ComputeCommandEncoder> encoder =
        [cache.commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    for (NSUInteger i = 0; i < elements; i++)
        [encoder copyFromBuffer:cache.vram
                   sourceOffset:p.address + i * p.stride
                       toBuffer:output
              destinationOffset:i * bytes
                           size:bytes];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    tr_idle(cache);
    return output;
}
static void sg_version(NV2AMetalSurfaceCache *cache, NSUInteger address,
                       NSUInteger length, uint64_t *version,
                       NV2AMetalCachedSurface **first)
{
    NSError *error = nil;
    NV2AMetalVRAMReadSpan span = { address, length };
    require([cache sourceVersionsForReadSpans:&span
                                        count:1
                                     versions:version
                                 firstSurface:first
                                        error:&error],
            error);
}
static NSData *sg_many(id<MTLDevice> device, BOOL reference)
{
    NSError *error = nil;
    TargetRetirementCache *cache = tr_cache(device, NULL);
    sg_owner = cache;
    sg_reference = reference;
    NV2AMetalSurfaceConfig c = tr_config();
    for (unsigned i = 0; i < 64; i++)
        require([cache selectSurfaceAtAddress:i * 256
                                       config:&c
                                        frame:0
                                        error:&error] != nil,
                error);
    assert(cache.count == 64);
    const NSUInteger address = 50000;
    uint64_t before, after, again;
    NV2AMetalCachedSurface *first = nil;
    sg_reset();
    sg_version(cache, address, 8, &before, &first);
    assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard, address, 8, YES));
    const uint64_t word = UINT64_C(0x123456789abcdef0);
    memcpy((uint8_t *)cache.vram.contents + address, &word, 8);
    sg_version(cache, address, 8, &after, &first);
    sg_version(cache, address, 8, &again, &first);
    NSUInteger sourceGets = sg_getters[1], sourceNo = sg_no[1],
               sourceYes = sg_yes[1];
    sg_reset();
    id<MTLBuffer> output =
        sg_copy(cache, (NV2AMetalVRAMReadPattern){ address, 8, 0, 0 });
    assert(*(uint64_t *)output.contents == word);
    assert(!first && after > before && again == after);
    assert(reference ?
               (sourceGets >= 64 && sourceYes == 3 && sg_getters[2] >= 64) :
               (!sourceGets && sourceNo == 3 && !sg_getters[2] && sg_no[2]));
    NSMutableData *result = [NSMutableData dataWithBytes:output.contents
                                                  length:8];
    uint64_t versions[] = { before, after, again };
    [result appendBytes:versions length:sizeof(versions)];
    /* A same-page hole is a conservative positive and must run the exact
     * byte scan. An actual overlap must still return the original binding. */
    for (unsigned overlap = 0; overlap < 2; overlap++) {
        first = nil;
        sg_reset();
        sg_version(cache, overlap ? 0 : 224, 8, &after, &first);
        assert(overlap ? (first && first.address == 0) : !first);
        assert(sg_yes[1] == 1 && sg_getters[1] >= 64);
        [result appendBytes:&after length:sizeof(after)];
    }
    require([cache discardForRestoreWithError:&error], error);
    return result;
}
static NSData *sg_dirty_and_holes(id<MTLDevice> device, BOOL reference)
{
    NSError *error = nil;
    TargetRetirementCache *cache = tr_cache(device, NULL);
    sg_owner = cache;
    sg_reference = reference;
    NV2AMetalSurfaceConfig c = tr_config();
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:4128
                                                              config:&c
                                                               frame:0
                                                               error:&error];
    require(surface != nil, error);
    clear_surface(cache, surface, MTLClearColorMake(0, 1, 0, 1), 0, 0);
    /* Four touched pages and one surface deliberately choose the bounded
     * broad/sparse fallback. The green surface occupies only a strided hole. */
    NV2AMetalVRAMReadPattern pattern = { 4096, 3 * 4096 + 4, 4096, 4 };
    sg_reset();
    id<MTLBuffer> holes = sg_copy(cache, pattern);
    for (unsigned i = 0; i < 4; i++)
        assert(((uint32_t *)holes.contents)[i] == UINT32_C(0x33333333));
    assert(surface.dirty && sg_yes[2] && sg_getters[2]);
    NSMutableData *result = [NSMutableData dataWithBytes:holes.contents
                                                  length:holes.length];
    uint64_t version;
    NV2AMetalCachedSurface *first = nil;
    sg_reset();
    sg_version(cache, surface.address, 16, &version, &first);
    assert(first == surface && version >= surface.generation && sg_yes[1] &&
           sg_getters[1]);
    [result appendBytes:&version length:sizeof(version)];
    sg_reset();
    id<MTLBuffer> selected =
        sg_copy(cache, (NV2AMetalVRAMReadPattern){ surface.address, 16, 0, 0 });
    for (unsigned i = 0; i < 4; i++)
        assert(((uint32_t *)selected.contents)[i] == UINT32_C(0xff00ff00));
    assert(!surface.dirty && sg_yes[2] && sg_getters[2]);
    [result appendBytes:selected.contents length:selected.length];
    /* Cancelled writes retain their valid target binding, but restore removes
     * it. Neither transition can manufacture a dirty hit or stale version. */
    require([cache prepareSurfaceAtAddress:surface.address
                                    config:&c
                                     frame:1
                                     error:&error] != nil,
            error);
    clear_surface(cache, surface, MTLClearColorMake(1, 0, 0, 1), 0, 0);
    [cache cancel];
    first = nil;
    sg_reset();
    sg_version(cache, surface.address, 4, &version, &first);
    assert(first == surface && !surface.dirty && sg_yes[1] && sg_getters[1]);
    require([cache discardForRestoreWithError:&error], error);
    first = nil;
    sg_reset();
    sg_version(cache, 4128, 4, &version, &first);
    assert(!first && !sg_getters[1]);
    sg_owner = nil;
    return result;
}
static void sg_faults_and_raw(id<MTLDevice> device)
{
    NSError *error = nil;
    CacheFailureCommands *commands;
    TargetRetirementCache *cache = tr_cache(device, &commands);
    sg_owner = cache;
    sg_reference = NO;
    NV2AMetalSurfaceConfig c = tr_config();
    require([cache selectSurfaceAtAddress:0 config:&c frame:0
                                    error:&error] != nil,
            error);
    uint64_t version = 0;
    NV2AMetalCachedSurface *first = nil;
    const NV2AMetalVRAMReadSpan invalid = { 65535, 2 };
    sg_reset();
    assert(![cache sourceVersionsForReadSpans:&invalid
                                        count:1
                                     versions:&version
                                 firstSurface:&first
                                        error:&error] &&
           error && !sg_calls[1] && !sg_getters[1]);
    NV2AMetalVRAMReadPattern bad = { 32768, 8, 4, 0 };
    error = nil;
    sg_reset();
    assert(![cache prepareGPUReadPattern:bad error:&error] && error &&
           !sg_calls[2] && !sg_getters[2]);
    gpu_dep_write(cache, 32768, UINT64_C(0x1020304050607080));
    tr_idle(cache);
    assert(*(uint64_t *)((uint8_t *)cache.vram.contents + 32768) ==
           UINT64_C(0x1020304050607080));
    sg_reset();
    sg_version(cache, 32768, 8, &version, &first);
    assert(!first && !sg_getters[1] && sg_no[1]);
    gpu_dep_write(cache, 32768, UINT64_C(0x8877665544332211));
    [cache cancel];
    id<MTLBuffer> copy =
        sg_copy(cache, (NV2AMetalVRAMReadPattern){ 32768, 8, 0, 0 });
    assert(*(uint64_t *)copy.contents == UINT64_C(0x1020304050607080));
    commands.failCompletion = YES;
    error = nil;
    assert(![cache waitUntilIdleWithError:&error] && error);
    sg_reset();
    error = nil;
    assert(![cache sourceVersionAtAddress:32768
                                   length:8
                                  version:&version
                                    error:&error] &&
           error && !sg_calls[1]);
    sg_reset();
    error = nil;
    NV2AMetalVRAMReadPattern valid = { 32768, 8, 0, 0 };
    assert(![cache prepareGPUReadPattern:valid error:&error] && error &&
           !sg_calls[2]);
    sg_owner = nil;
}
static void surface_negative_gate_tests(id<MTLDevice> device)
{
    Class surface = NV2AMetalCachedSurface.class,
          cache = NV2AMetalSurfaceCache.class;
    Method methods[] = {
        class_getInstanceMethod(
            cache, @selector(surfaceTargetsMayOverlapAddress:length:)),
        class_getInstanceMethod(cache,
                                @selector(sourceVersionForValidatedSpan:version:
                                          containingSurface:error:)),
        class_getInstanceMethod(
            cache,
            @selector(findDirtySurfacesForReadPatterns:count:bounds:selected:)),
        class_getInstanceMethod(surface, @selector(address)),
        class_getInstanceMethod(surface, @selector(reservationLength)),
        class_getInstanceMethod(surface, @selector(generation)),
        class_getInstanceMethod(surface, @selector(dirty))
    };
    IMP originals[7];
    for (unsigned i = 0; i < 7; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    sg_gate_original = (void *)originals[0];
    sg_source_original = (void *)originals[1];
    sg_dirty_original = (void *)originals[2];
    sg_address_original = (void *)originals[3];
    sg_length_original = (void *)originals[4];
    sg_generation_original = (void *)originals[5];
    sg_surface_dirty_original = (void *)originals[6];
    IMP hooks[] = { (IMP)sg_gate,         (IMP)sg_source, (IMP)sg_dirty,
                    (IMP)sg_address,      (IMP)sg_length, (IMP)sg_generation,
                    (IMP)sg_surface_dirty };
    for (unsigned i = 0; i < 7; i++)
        method_setImplementation(methods[i], hooks[i]);
    @try {
        NSData *candidate = sg_many(device, NO),
               *reference = sg_many(device, YES);
        assert([candidate isEqualToData:reference]);
        candidate = sg_dirty_and_holes(device, NO);
        reference = sg_dirty_and_holes(device, YES);
        assert([candidate isEqualToData:reference]);
        sg_faults_and_raw(device);
    } @finally {
        sg_owner = nil;
        sg_role = 0;
        sg_reference = NO;
        for (unsigned i = 0; i < 7; i++)
            method_setImplementation(methods[i], originals[i]);
    }
    puts("Surface negative gate:64 live disjoint bindings,zero scoped surface "
         "getters versus old exact scan; GPU/sourceversion/firstSurface A/B, "
         "same-page positives,strided holes,dirty "
         "surface/download,cancel/Restore/raw/error guards PASS");
    checks++;
}
#endif
