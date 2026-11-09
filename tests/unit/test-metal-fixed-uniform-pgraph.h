/* Real equal-sized Fixed DrawArrays ranges share one immutable parameter
 * upload. SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_FIXED_UNIFORM_PGRAPH_H
#define TEST_METAL_FIXED_UNIFORM_PGRAPH_H
#include "hw/xbox/nv2a/pgraph/metal/vertex-fixed-types.h"
_Static_assert(sizeof(NV2AMetalFixedParameters) == 5352,
               "Fixed parameter upload ABI");
static BOOL fup_active, fup_reference;
static unsigned fup_address_depth, fup_addresses, fup_uploads;
static NSUInteger fup_bytes, fup_xf_records, fup_fetch_records;
static const void *fup_current_parameters;
static NSData *fup_parameters;
static MTLGPUAddress (*fup_address_original)(id, SEL,
                                             const NV2AMetalFixedParameters *,
                                             id, NSError **);
static MTLGPUAddress fup_address(id engine, SEL selector,
                                 const NV2AMetalFixedParameters *parameters,
                                 NV2AMetalCommands *commands, NSError **error)
{
    if (!fup_active)
        return fup_address_original(engine, selector, parameters, commands,
                                    error);
    fup_addresses++;
    if (!fup_parameters)
        fup_parameters = [NSData dataWithBytes:parameters
                                        length:sizeof(*parameters)];
    else
        assert(!memcmp(fup_parameters.bytes, parameters, sizeof(*parameters)));
    fup_address_depth++;
    fup_current_parameters = parameters;
    MTLGPUAddress address;
    if (fup_reference) {
        // Exactly the pre-cache upload: one complete struct per Fixed encode.
        NSUInteger offset = 0;
        id<MTLBuffer> buffer = [commands uploadBytes:parameters
                                              length:sizeof(*parameters)
                                              offset:&offset
                                               error:error];
        address = buffer ? buffer.gpuAddress + offset : 0;
    } else
        address =
            fup_address_original(engine, selector, parameters, commands, error);
    fup_current_parameters = NULL;
    fup_address_depth--;
    return address;
}
static id (*fup_upload_original)(id, SEL, const void *, NSUInteger,
                                 NSUInteger *, NSError **);
static id fup_upload(id commands, SEL selector, const void *bytes,
                     NSUInteger length, NSUInteger *offset, NSError **error)
{
    if (fup_active && fup_address_depth && bytes == fup_current_parameters) {
        assert(length == 5352);
        fup_uploads++;
        fup_bytes += length;
    }
    return fup_upload_original(commands, selector, bytes, length, offset,
                               error);
}
static id (*fup_encode_original)(id, SEL, id, id, NSUInteger, NSUInteger, id,
                                 id, NSError **);
static id fup_encode(id object, SEL selector, id vertex, id attributes,
                     NSUInteger first, NSUInteger count, id fetch, id commands,
                     NSError **error)
{
    if (fup_active)
        fup_xf_records += count;
    return fup_encode_original(object, selector, vertex, attributes, first,
                               count, fetch, commands, error);
}
static id (*fup_execute_original)(id, SEL, id, id, NSUInteger, NSUInteger,
                                  NSError **);
static id fup_execute(id object, SEL selector, id vertex, id attributes,
                      NSUInteger first, NSUInteger count, NSError **error)
{
    if (fup_active)
        fup_xf_records += count;
    return fup_execute_original(object, selector, vertex, attributes, first,
                                count, error);
}
static id (*fup_current_original)(id, SEL, id, id, BOOL, uint64_t, NSError **);
static id (*fup_independent_original)(id, SEL, id, id, BOOL, uint64_t,
                                      NSError **);
static id fup_fetch_result(NSArray<NV2AMetalPGRAPHFetchBatch *> *batches)
{
    if (fup_active)
        for (NV2AMetalPGRAPHFetchBatch *batch in batches)
            fup_fetch_records += batch.physicalVertexCount;
    return batches;
}
static id fup_current(id object, SEL selector, id prefixes, id input,
                      BOOL dedupe, uint64_t proofLanes, NSError **error)
{
    return fup_fetch_result(fup_current_original(
        object, selector, prefixes, input, dedupe, proofLanes, error));
}
static id fup_independent(id object, SEL selector, id prefixes, id input,
                          BOOL dedupe, uint64_t proofLanes, NSError **error)
{
    return fup_fetch_result(fup_independent_original(
        object, selector, prefixes, input, dedupe, proofLanes, error));
}
static NSData *fup_run(unsigned scene, BOOL reference)
{
    fup_active = NO;
    fixture();
    PGRAPHState *pg = &state->pgraph;
    unsigned ranges = scene ? 4 : 3;
    pg->primitive_mode = scene ? PRIM_TYPE_POINTS : PRIM_TYPE_TRIANGLES;
    pg->draw_arrays_length = ranges;
    pg->vertex_attributes[3] =
        (VertexAttribute){ .offset = 256,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 4,
                           .stride = 16 };
    float positions[12][4], colors[12][4];
    for (unsigned i = 0; i < ranges * 3; i++) {
        const float xy[3][2] = { { .5f, .5f }, { 7.5f, .5f }, { .5f, 7.5f } };
        positions[i][0] = scene ? (i % 4) * 2 + .5f : xy[i % 3][0];
        positions[i][1] = scene ? (i / 4) * 2 + .5f : xy[i % 3][1];
        positions[i][2] = 30000 + i * 100;
        positions[i][3] = 1;
        colors[i][0] = i / 3 == 0 || i / 3 == 3;
        colors[i][1] = i / 3 == 1 || i / 3 == 3;
        colors[i][2] = i / 3 == 2;
        colors[i][3] = 1;
    }
    for (unsigned i = 0; i < ranges; i++) {
        pg->draw_arrays_start[i] = i * 3;
        pg->draw_arrays_count[i] = 3;
    }
    cpu_write(16384, ranges * 3 * 16);
    memcpy(state->vram_ptr + 16384, positions, ranges * 3 * 16);
    cpu_write(16640, ranges * 3 * 16);
    memcpy(state->vram_ptr + 16640, colors, ranges * 3 * 16);
    pg->surface_shape.zeta_format = 2;
    pg->surface_zeta.pitch = 32;
    pg->regs_[NV_PGRAPH_CONTROL_0] |= NV_PGRAPH_CONTROL_0_ZENABLE |
                                      NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                                      NV_PGRAPH_CONTROL_0_ZFUNC_ALWAYS << 16;
    pg->regs_[NV_PGRAPH_POINTSIZE] = 8;
    pg->zpass_pixel_count_enable = true;
    pg->dma_report = 80;
    NSError *error = nil;
    qemu_mutex_lock(&pg->lock);
    [draw.reports clear];
    fup_addresses = fup_uploads = 0;
    fup_bytes = fup_xf_records = fup_fetch_records = 0;
    fup_parameters = nil;
    fup_reference = reference;
    fup_active = YES;
    require([draw drawWithError:&error], error);
    fup_active = NO;
    assert(fup_addresses == ranges && fup_uploads == (reference ? ranges : 1) &&
           fup_bytes == (reference ? ranges : 1) * 5352u &&
           fup_xf_records == ranges * 3 && fup_fetch_records == ranges * 3);
    require([surfaces.cache submitWithError:&error] &&
                [surfaces.cache waitUntilIdleWithError:&error],
            error);
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, 256);
    read_vram(4096, 256);
    qemu_mutex_lock(&pg->lock);
    require([draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error],
            error);
    uint32_t query = report_value(0);
    assert(query && pg->draw_time == 1);
    assert(!memcmp(pg->vertex_attributes[3].inline_value,
                   colors[ranges * 3 - 1], 16));
    NSData *result = cpp_capture(query);
    qemu_mutex_unlock(&pg->lock);
    fup_parameters = nil;
    return result;
}
static void fixed_uniform_pgraph_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalVertexFixed.class,
            sel_registerName("addressForParameters:commands:error:")),
        class_getInstanceMethod(NV2AMetalCommands.class,
                                @selector(uploadBytes:length:offset:error:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeRasterState:attributeBuffer:first:count:
                      attributeFetch:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(executeRasterState:attributeBuffer:first:count:error:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(encodeCurrentSnapshotsWithPrefixes:indexedInput:
                      deduplicateReadonly:proofAttributeLanes:error:)),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            @selector(encodeIndependentSnapshotsWithPrefixes:indexedInput:
                      deduplicateReadonly:proofAttributeLanes:error:))
    };
    IMP replacements[] = { (IMP)fup_address, (IMP)fup_upload,
                           (IMP)fup_encode,  (IMP)fup_execute,
                           (IMP)fup_current, (IMP)fup_independent },
        originals[6];
    for (unsigned i = 0; i < 6; i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], replacements[i]);
    }
    fup_address_original = (void *)originals[0];
    fup_upload_original = (void *)originals[1];
    fup_encode_original = (void *)originals[2];
    fup_execute_original = (void *)originals[3];
    fup_current_original = (void *)originals[4];
    fup_independent_original = (void *)originals[5];
    @try {
        for (unsigned scene = 0; scene < 2; scene++)
            @autoreleasepool {
                NSData *result[2];
                for (unsigned order = 0; order < 2; order++) {
                    unsigned reference = (order + scene) & 1;
                    result[reference] = fup_run(scene, reference);
                }
                assert([result[0] isEqualToData:result[1]]);
            }
    } @finally {
        fup_active = NO;
        fup_parameters = nil;
        for (unsigned i = 0; i < 6; i++)
            method_setImplementation(methods[i], originals[i]);
    }
    puts("Fixed uniforms PGRAPH:2 exact framebuffer/zeta/Current/context/query "
         "pairs; identical 5352-byte blocks, unchanged Fetch/XF records, real "
         "parameter uploads 3/4 to1 (16056/21408 to5352 bytes) PASS");
    groups += 2;
}
#endif
