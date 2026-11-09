/* Real inline recaptures versus the old always-fresh descriptor route.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_INLINE_INPUT_REUSE_PGRAPH_H
#define TEST_METAL_INLINE_INPUT_REUSE_PGRAPH_H
#import "hw/xbox/nv2a/pgraph/metal/pending-pgraph.h"
static BOOL ipr_active, ipr_reference;
static _Thread_local BOOL ipr_count;
static _Thread_local unsigned ipr_input_inits, ipr_plan_inits;
static NSUInteger ipr_xf_records;
static NSArray *(*ipr_inputs_original)(id, SEL, PGRAPHState *, NSArray *,
                                       NSError **);
static NSArray *ipr_inputs(id cls, SEL selector, PGRAPHState *pg,
                           NSArray *previous, NSError **error)
{
    return ipr_inputs_original(
        cls, selector, pg,
        ipr_active && ipr_reference && pg == &state->pgraph ? nil : previous,
        error);
}
@interface NV2AMetalPendingInput (InlineReuseGPUCounter)
- (instancetype)ipr_initKind:(NV2AMetalInputKind)kind
                       first:(NSUInteger)first
                       count:(NSUInteger)count
                     indices:(NSData *)indices
              verifiedPrefix:(NV2AMetalPendingInput *)prefix
    __attribute__((objc_method_family(init)));
@end
@implementation NV2AMetalPendingInput (InlineReuseGPUCounter)
- (instancetype)ipr_initKind:(NV2AMetalInputKind)kind
                       first:(NSUInteger)first
                       count:(NSUInteger)count
                     indices:(NSData *)indices
              verifiedPrefix:(NV2AMetalPendingInput *)prefix
{
    if (ipr_count)
        ipr_input_inits++;
    return [self ipr_initKind:kind
                        first:first
                        count:count
                      indices:indices
               verifiedPrefix:prefix];
}
@end
@interface NV2AMetalPendingPlan (InlineReuseGPUCounter)
- (instancetype)ipr_initInputs:(NSArray *)inputs
                      prefixes:(NSArray *)prefixes
                      previous:(NSArray *)previous
                         owner:(NV2AMetalPendingJournal *)owner
                       version:(NSUInteger)version
    __attribute__((objc_method_family(init)));
@end
@implementation NV2AMetalPendingPlan (InlineReuseGPUCounter)
- (instancetype)ipr_initInputs:(NSArray *)inputs
                      prefixes:(NSArray *)prefixes
                      previous:(NSArray *)previous
                         owner:(NV2AMetalPendingJournal *)owner
                       version:(NSUInteger)version
{
    if (ipr_count)
        ipr_plan_inits++;
    return [self ipr_initInputs:inputs
                       prefixes:prefixes
                       previous:previous
                          owner:owner
                        version:version];
}
@end
static id (*ipr_encode_original)(id, SEL, id, id, NSUInteger, NSUInteger, id,
                                 id, NSError **);
static id ipr_encode(id object, SEL selector, id vertex, id attributes,
                     NSUInteger first, NSUInteger count, id fetch, id commands,
                     NSError **error)
{
    if (ipr_active)
        ipr_xf_records += count;
    return ipr_encode_original(object, selector, vertex, attributes, first,
                               count, fetch, commands, error);
}
static id (*ipr_execute_original)(id, SEL, id, id, NSUInteger, NSUInteger,
                                  NSError **);
static id ipr_execute(id object, SEL selector, id vertex, id attributes,
                      NSUInteger first, NSUInteger count, NSError **error)
{
    if (ipr_active)
        ipr_xf_records += count;
    return ipr_execute_original(object, selector, vertex, attributes, first,
                                count, error);
}
@interface InlineReusePGRAPHOutput : NSObject
@property(nonatomic) NSArray<NSData *> *images, *archives;
@property(nonatomic) unsigned inputInits, planInits;
@property(nonatomic) NSUInteger xfRecords;
@property(nonatomic) NSData *current;
@end
@implementation InlineReusePGRAPHOutput
@end
static void ipr_payload(PGRAPHState *pg, BOOL packed, NSUInteger count,
                        float position[6][4], float colors[6][4])
{
    if (!packed) {
        pg->inline_buffer_length = (unsigned)count;
        pg->vertex_attributes[0].inline_buffer = &position[0][0];
        pg->vertex_attributes[3].inline_buffer = &colors[0][0];
        pg->vertex_attributes[0].inline_buffer_populated = true;
        pg->vertex_attributes[3].inline_buffer_populated = true;
    } else {
        pg->inline_array_length = (unsigned)count * 8;
        for (NSUInteger i = 0; i < count; i++) {
            memcpy(pg->inline_array + i * 8, position[i], 16);
            memcpy(pg->inline_array + i * 8 + 4, colors[i], 16);
        }
    }
}
static NSData *ipr_frame(PGRAPHState *pg)
{
    qemu_mutex_unlock(&pg->lock);
    read_vram(1024, 256);
    read_vram(4096, 256);
    qemu_mutex_lock(&pg->lock);
    NSError *error = nil;
    require([draw.reports getReport:1u << 24 error:&error] &&
                [draw.reports processWithError:&error],
            error);
    uint32_t query = report_value(0);
    require(query != 0, nil);
    return cpp_capture(query);
}
static InlineReusePGRAPHOutput *ipr_run(BOOL packed, BOOL reference)
{
    ipr_active = NO;
    fixture();
    PGRAPHState *pg = &state->pgraph;
    inline_fixed_context(pg, 2); // Readonly program: position V0, color V3.
    pg->draw_arrays_length = 0;
    pg->surface_shape.zeta_format = 2;
    pg->surface_zeta.pitch = 32;
    pg->regs_[NV_PGRAPH_CONTROL_0] |= NV_PGRAPH_CONTROL_0_ZENABLE |
                                      NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                                      NV_PGRAPH_CONTROL_0_ZFUNC_ALWAYS << 16;
    pg->dma_report = 80;
    pg->zpass_pixel_count_enable = true;
    pg->vertex_attributes[3].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
    pg->vertex_attributes[3].count = 4;
    pg->vertex_attributes[3].size = 4;
    float position[6][4] = { { 0, 0, 32768, 1 }, { 8, 0, 32768, 1 },
                             { 0, 8, 32768, 1 }, { 8, 8, 32768, 1 },
                             { 0, 8, 32768, 1 }, { 8, 0, 32768, 1 } };
    float colors[6][4];
    const float green[] = { 0, 1, 0, 1 }, blue[] = { 0, 0, 1, 1 };
    for (unsigned i = 0; i < 6; i++)
        memcpy(colors[i], i < 3 ? green : blue, 16);
    ipr_payload(pg, packed, 3, position, colors);
    NSError *error = nil;
    NSMutableArray *archives = [NSMutableArray new],
                   *images = [NSMutableArray new];
    InlineReusePGRAPHOutput *out = [InlineReusePGRAPHOutput new];
    qemu_mutex_lock(&pg->lock);
    [draw.reports clear];
    ipr_active = YES;
    ipr_reference = reference;
    ipr_xf_records = 0;
    require([draw beginWithError:&error] &&
                [draw prepareVertexStateChangeWithError:&error],
            error);
    ipr_input_inits = ipr_plan_inits = 0;
    ipr_count = YES;
    for (unsigned repeat = 0; repeat < 8; repeat++)
        require([draw prepareVertexStateChangeWithError:&error], error);
    ipr_count = NO;
    out.inputInits = ipr_input_inits;
    out.planInits = ipr_plan_inits;
    NSData *old = [draw pendingSnapshotWithError:&error];
    require(old.length > 12, error);
    [archives addObject:old];
    /* A count-identical recapture froze no guest payload: mutate the old host
     * prefix, then add a real suffix. The first GPU vertices remain green. */
    for (unsigned i = 0; i < 3; i++)
        memcpy(colors[i], blue, 16);
    ipr_payload(pg, packed, 6, position, colors);
    require([draw prepareVertexStateChangeWithError:&error], error);
    NSData *grown = [draw pendingSnapshotWithError:&error];
    require(grown.length > old.length, error);
    [archives addObject:grown];
    NSData *vertex = draw.vertexSnapshot;
    NSData *begin = [draw beginSnapshotWithError:&error];
    require(vertex && begin && [draw flushWithError:&error] &&
                [draw discardForRestoreWithError:&error] &&
                [draw restoreVertexSnapshot:vertex error:&error] &&
                [draw restoreBeginSnapshot:begin error:&error] &&
                [draw restorePendingSnapshot:grown error:&error] &&
                [draw beginWithError:&error],
            error);
    NSData *restored = [draw pendingSnapshotWithError:&error];
    require(restored != nil, error);
    [archives addObject:restored];
    NSData *checkpoint = cpp_capture(0);
    inline_fixed_fail = YES;
    assert(![draw flushDrawWithError:&error] && error && !inline_fixed_fail &&
           [error.domain isEqualToString:@"test.inline-fixed"] &&
           [checkpoint isEqualToData:cpp_capture(0)]);
    error = nil;
    require([draw endWithError:&error], error);
    [images addObject:ipr_frame(pg)];
    /* A new draw of the same count must fetch the now-blue live payload. */
    ipr_payload(pg, packed, 6, position, colors);
    require([draw drawWithError:&error], error);
    [images addObject:ipr_frame(pg)];
    out.current = [NSData dataWithBytes:pg->vertex_attributes[3].inline_value
                                 length:16];
    out.xfRecords = ipr_xf_records;
    out.images = images;
    out.archives = archives;
    ipr_active = NO;
    qemu_mutex_unlock(&pg->lock);
    return out;
}
static void inline_input_reuse_pgraph_tests(void)
{
    Method methods[] = {
        class_getClassMethod(NV2AMetalPGRAPHPendingInputs.class,
                             @selector(inputsWithState:reusingInputs:error:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeRasterState:attributeBuffer:first:count:
                      attributeFetch:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(executeRasterState:attributeBuffer:first:count:error:)),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:)),
    };
    IMP wrappers[] = { (IMP)ipr_inputs, (IMP)ipr_encode, (IMP)ipr_execute,
                       (IMP)inline_fixed_emit };
    IMP originals[4];
    for (unsigned i = 0; i < 4; i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    ipr_inputs_original = (void *)originals[0];
    ipr_encode_original = (void *)originals[1];
    ipr_execute_original = (void *)originals[2];
    inline_fixed_original_emit = (void *)originals[3];
    Method constructors[] = {
        class_getInstanceMethod(
            NV2AMetalPendingInput.class,
            sel_registerName("initKind:first:count:indices:verifiedPrefix:")),
        class_getInstanceMethod(
            NV2AMetalPendingPlan.class,
            sel_registerName("initInputs:prefixes:previous:owner:version:")),
    };
    Method counters[] = {
        class_getInstanceMethod(
            NV2AMetalPendingInput.class,
            @selector(ipr_initKind:first:count:indices:verifiedPrefix:)),
        class_getInstanceMethod(
            NV2AMetalPendingPlan.class,
            @selector(ipr_initInputs:prefixes:previous:owner:version:)),
    };
    for (unsigned i = 0; i < 4; i++)
        method_setImplementation(methods[i], wrappers[i]);
    for (unsigned i = 0; i < 2; i++) {
        assert(constructors[i] && counters[i]);
        method_exchangeImplementations(constructors[i], counters[i]);
    }
    @try {
        for (unsigned packed = 0; packed < 2; packed++) {
            InlineReusePGRAPHOutput *reference = ipr_run(packed, YES);
            InlineReusePGRAPHOutput *actual = ipr_run(packed, NO);
            // Completed framebuffer/zeta/Current/constants/query bytes first.
            assert([actual.images isEqualToArray:reference.images]);
            const uint32_t *first = ((NSData *)actual.images[0]).bytes;
            const uint32_t *fresh = ((NSData *)actual.images[1]).bytes;
            assert(first[9] == 0xff00ff00 && fresh[9] == 0xff0000ff);
            assert([actual.archives isEqualToArray:reference.archives]);
            assert([actual.archives[1] isEqualToData:actual.archives[2]]);
            const float blue[] = { 0, 0, 1, 1 };
            assert(!memcmp(actual.current.bytes, blue, 16));
            assert(actual.inputInits == 0 && actual.planInits == 1 &&
                   reference.inputInits == 8 && reference.planInits == 8 &&
                   actual.xfRecords == 12 && reference.xfRecords == 12);
        }
    } @finally {
        ipr_active = ipr_count = inline_fixed_fail = NO;
        for (unsigned i = 0; i < 2; i++)
            method_exchangeImplementations(constructors[i], counters[i]);
        for (unsigned i = 0; i < 4; i++)
            method_setImplementation(methods[i], originals[i]);
    }
    puts("Inline descriptor reuse PGRAPH: 2 exact GPU "
         "image/depth/Current/constants/query "
         "and archive pairs; warm ctor/plan counts 0/1 versus8/8, suffix "
         "growth, "
         "payload mutation, Restore and late emit retry PASS");
    groups++;
}
#endif
