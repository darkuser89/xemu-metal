/* Effective depth/stencil cache parity, pressure and native lifetime tests.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DEPTH_STENCIL_CACHE_H
#define TEST_METAL_DEPTH_STENCIL_CACHE_H
#import "hw/xbox/nv2a/pgraph/metal/lru-cache.h"
#import <objc/runtime.h>
#include <time.h>

static IMP ds_original_lookup, ds_original_build;
static uint64_t ds_last_key;
static MTLDepthStencilDescriptor *ds_last_descriptor;
static BOOL ds_fail_build, ds_uncached;
static NV2AMetalDrawConfig ds_reference_config;
static unsigned ds_reference_requests;

/* Independent reconstruction of the pre-cache native descriptor contract. */
static MTLDepthStencilDescriptor *ds_reference(const NV2AMetalDrawConfig *c)
{
    const MTLCompareFunction compare[] = {
        MTLCompareFunctionNever,        MTLCompareFunctionLess,
        MTLCompareFunctionEqual,        MTLCompareFunctionLessEqual,
        MTLCompareFunctionGreater,      MTLCompareFunctionNotEqual,
        MTLCompareFunctionGreaterEqual, MTLCompareFunctionAlways
    };
    const MTLStencilOperation operations[] = {
        MTLStencilOperationKeep,           MTLStencilOperationKeep,
        MTLStencilOperationZero,           MTLStencilOperationReplace,
        MTLStencilOperationIncrementClamp, MTLStencilOperationDecrementClamp,
        MTLStencilOperationInvert,         MTLStencilOperationIncrementWrap,
        MTLStencilOperationDecrementWrap
    };
    MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
    BOOL enabled = !!(c->control[0] & NV_PGRAPH_CONTROL_0_ZENABLE);
    d.depthCompareFunction =
        enabled ? compare[(c->control[0] >> 16) & 7] : MTLCompareFunctionAlways;
    d.depthWriteEnabled =
        enabled && !!(c->control[0] & NV_PGRAPH_CONTROL_0_ZWRITEENABLE);
    if (c->control[1] & NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE) {
        MTLStencilDescriptor *s = [MTLStencilDescriptor new];
        s.stencilCompareFunction = compare[(c->control[1] >> 4) & 7];
        s.stencilFailureOperation = operations[c->control[2] & 15];
        s.depthFailureOperation = operations[(c->control[2] >> 4) & 15];
        s.depthStencilPassOperation = operations[(c->control[2] >> 8) & 15];
        s.readMask = (c->control[1] >> 16) & 255;
        s.writeMask = c->control[1] >> 24;
        d.frontFaceStencil = d.backFaceStencil = s;
    }
    return d;
}
static NSData *ds_signature(MTLDepthStencilDescriptor *d)
{
    NSUInteger fields[17] = { d.depthCompareFunction, d.depthWriteEnabled };
    MTLStencilDescriptor *faces[] = { d.frontFaceStencil, d.backFaceStencil };
    for (unsigned i = 0; i < 2; i++) {
        MTLStencilDescriptor *s = faces[i];
        NSUInteger *v = fields + 2 + i * 7;
        v[0] = s != nil;
        if (s) {
            v[1] = s.stencilCompareFunction;
            v[2] = s.stencilFailureOperation;
            v[3] = s.depthFailureOperation;
            v[4] = s.depthStencilPassOperation;
            v[5] = s.readMask;
            v[6] = s.writeMask;
        }
    }
    return [NSData dataWithBytes:fields length:sizeof(fields)];
}
static id ds_lookup(id owner, SEL selector, uint64_t key, NSError **error)
{
    ds_last_key = key;
    if (ds_uncached) {
        ds_reference_requests++;
        id<MTLDevice> device = [owner valueForKey:@"device"];
        return [device
            newDepthStencilStateWithDescriptor:ds_reference(
                                                   &ds_reference_config)];
    }
    return ((id (*)(id, SEL, uint64_t, NSError **))ds_original_lookup)(
        owner, selector, key, error);
}
typedef id (*DSBuildIMP)(id, SEL, id) __attribute__((ns_returns_retained));
static id ds_build(id owner, SEL selector, MTLDepthStencilDescriptor *d)
    __attribute__((ns_returns_retained));
static id ds_build(id owner, SEL selector, MTLDepthStencilDescriptor *d)
{
    ds_last_descriptor = [d copy];
    if (ds_fail_build)
        return nil;
    return ((DSBuildIMP)ds_original_build)(owner, selector, d);
}
static NV2AMetalDrawState *ds_capture(NV2AMetalDrawConfig c)
{
    NSError *error = nil;
    NV2AMetalDrawState *r =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&c
                                             error:&error];
    require(r != nil, error);
    return r;
}
static NV2AMetalDrawConfig ds_config(void)
{
    return (NV2AMetalDrawConfig){
        .control = { NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_ZENABLE |
                         NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 1 << 16,
                     NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 7 << 4 |
                         0xff00ff00u,
                     1 | 1 << 4 | 3 << 8 },
        .viewport_width = 8,
        .viewport_height = 8
    };
}
static unsigned ds_checked_configs;
static void ds_check(NV2AMetalDrawConfig c, NSMutableDictionary *signatures,
                     NSMutableDictionary *keys)
{
    ds_last_descriptor = nil;
    NV2AMetalDrawState *r = ds_capture(c);
    assert(r.requiresDepth == !!(c.control[0] & NV_PGRAPH_CONTROL_0_ZENABLE));
    assert(r.requiresStencil ==
           !!(c.control[1] & NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE));
    NSData *reference = ds_signature(ds_reference(&c));
    NSNumber *key = @(ds_last_key);
    if (signatures[key])
        assert([signatures[key] isEqual:reference]);
    else
        signatures[key] = reference;
    if (keys[reference])
        assert([keys[reference] isEqual:key]);
    else
        keys[reference] = key;
    if (ds_last_descriptor)
        assert([ds_signature(ds_last_descriptor) isEqual:reference]);
    NV2AMetalLRUCache *lru =
        [[r valueForKey:@"depthStencilCache"] valueForKey:@"states"];
    assert(lru.count <= 256);
    ds_checked_configs++;
}
static id<MTLBuffer> ds_readback(id<MTLTexture> texture, BOOL stencil)
{
    NSError *error = nil;
    id<MTLBuffer> b =
        [commands.device newBufferWithLength:8 * 256
                                     options:MTLResourceStorageModeShared];
    require([commands addResource:b error:&error], error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:texture
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(8, 8, 1)
                        toBuffer:b
               destinationOffset:0
          destinationBytesPerRow:256
        destinationBytesPerImage:0
                         options:stencil ?
                                     MTLBlitOptionStencilFromDepthStencil :
                                     MTLBlitOptionDepthFromDepthStencil];
    [e endEncoding];
    return b;
}
static NSArray *ds_gpu_trace(NV2AMetalPixelShader *pixelShader,
                             NV2AMetalDrawConfig config, BOOL reference)
{
    NSError *error = nil;
    id<MTLTexture> color = target(8, 8);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                     width:8
                                    height:8
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> zeta = [commands.device newTextureWithDescriptor:td];
    assert(zeta);
    for (unsigned drawIndex = 0; drawIndex < 3; drawIndex++) {
        NV2AMetalDrawConfig c = config;
        c.control[1] = (c.control[1] & ~NV_PGRAPH_CONTROL_1_STENCIL_REF) |
                       (unsigned[]){ 0, 127, 255 }[drawIndex] << 8;
        c.blend_color += drawIndex;
        NV2AMetalDrawState *raster = ds_capture(c);
        if (reference) {
            id<MTLDepthStencilState> fresh = [commands.device
                newDepthStencilStateWithDescriptor:ds_reference(&c)];
            assert(fresh);
            [raster setValue:fresh forKey:@"depthStencil"];
        }
        NV2AMetalVertex v[6] = { 0 };
        const float xy[6][2] = { { -1, -1 }, { 1, -1 }, { -1, 1 },
                                 { 1, -1 },  { 1, 1 },  { -1, 1 } };
        for (unsigned i = 0; i < 6; i++) {
            v[i].clip[0] = xy[i][0];
            v[i].clip[1] = xy[i][1];
            v[i].clip[2] = .5f;
            v[i].clip[3] = 1;
            v[i].color[0][drawIndex] = 1;
            v[i].color[0][3] = 1;
            for (unsigned k = 0; k < 3; k++) {
                v[i].plane[k][2] = 16777215.f * (.25f + drawIndex * .25f);
                v[i].plane[k][3] = 1;
            }
            v[i].plane[1][0] = v[i].plane[2][1] = 8;
        }
        id<MTLBuffer> vertices =
            [commands.device newBufferWithBytes:v
                                         length:sizeof(v)
                                        options:MTLResourceStorageModeShared];
        NV2AMetalPixelUniforms u = { .smooth_shading = 1,
                                     .clip_range = { 0, 65535, 0, 65535 },
                                     .clip_regions = { { 0, 0, 8, 8 } },
                                     .surface_scale = { 1, 1 },
                                     .depth_format = NV2AMetalPixelDepthD24 };
        u.combiner.final_inputs[0] = PS_REGISTER_V0;
        u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
        NV2AMetalPixelTexture textures[4] = { 0 };
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        pass.colorAttachments[0].texture = color;
        pass.colorAttachments[0].loadAction =
            drawIndex ? MTLLoadActionLoad : MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor =
            MTLClearColorMake(.125, .25, .5, 1);
        pass.depthAttachment.texture = pass.stencilAttachment.texture = zeta;
        pass.depthAttachment.loadAction = pass.stencilAttachment.loadAction =
            drawIndex ? MTLLoadActionLoad : MTLLoadActionClear;
        pass.depthAttachment.storeAction = pass.stencilAttachment.storeAction =
            MTLStoreActionStore;
        pass.depthAttachment.clearDepth = .5;
        pass.stencilAttachment.clearStencil = 127;
        require([pixelShader encodeVertices:vertices
                                      count:6
                                  primitive:MTLPrimitiveTypeTriangle
                                   uniforms:&u
                                   textures:textures
                                       pass:pass
                                  drawState:raster
                                   commands:commands
                                      error:&error],
                error);
    }
    return @[ color, ds_readback(zeta, NO), ds_readback(zeta, YES) ];
}
static double ds_clock(void)
{
    struct timespec t;
    assert(!clock_gettime(CLOCK_MONOTONIC, &t));
    return t.tv_sec * 1000. + t.tv_nsec / 1000000.;
}
static int ds_time_compare(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static void depth_stencil_cache_tests(void)
{
    __weak NV2AMetalDepthStencilCache *releasedCache;
    @autoreleasepool {
        NV2AMetalDrawState *first = ds_capture(ds_config());
        releasedCache = [first valueForKey:@"depthStencilCache"];
        @autoreleasepool {
            assert(releasedCache);
        }
    }
    assert(!releasedCache);
    Class cacheClass = NSClassFromString(@"NV2AMetalDepthStencilCache");
    assert(cacheClass);
    Method lookup =
        class_getInstanceMethod(cacheClass, @selector(stateForKey:error:));
    Method build =
        class_getInstanceMethod(cacheClass, @selector(newStateWithDescriptor:));
    ds_original_lookup = method_setImplementation(lookup, (IMP)ds_lookup);
    ds_original_build = method_setImplementation(build, (IMP)ds_build);
    NV2AMetalDrawConfig c = ds_config();
    NV2AMetalDrawState *anchor = ds_capture(c);
    id cache = [anchor valueForKey:@"depthStencilCache"];
    NV2AMetalLRUCache *lru = [cache valueForKey:@"states"];
    [lru removeAllObjects];
    NSMutableDictionary *signatures = [NSMutableDictionary new],
                        *keys = [NSMutableDictionary new];
    for (unsigned enabled = 0; enabled < 2; enabled++)
        for (unsigned compare = 0; compare < 8; compare++)
            for (unsigned write = 0; write < 2; write++) {
                NV2AMetalDrawConfig v = c;
                v.control[0] =
                    (v.control[0] & ~(NV_PGRAPH_CONTROL_0_ZENABLE |
                                      NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                                      NV_PGRAPH_CONTROL_0_ZFUNC)) |
                    enabled << 14 | write << 24 | compare << 16;
                ds_check(v, signatures, keys);
            }
    for (unsigned compare = 0; compare < 8; compare++)
        for (unsigned fail = 1; fail <= 8; fail++)
            for (unsigned zfail = 1; zfail <= 8; zfail++)
                for (unsigned pass = 1; pass <= 8; pass++) {
                    c.control[1] =
                        (c.control[1] & ~NV_PGRAPH_CONTROL_1_STENCIL_FUNC) |
                        compare << 4;
                    c.control[2] = fail | zfail << 4 | pass << 8;
                    ds_check(c, signatures, keys);
                }
    c = ds_config();
    for (unsigned mask = 0; mask < 256; mask++)
        for (unsigned write = 0; write < 2; write++) {
            NV2AMetalDrawConfig v = c;
            unsigned shift = write ? 24 : 16;
            v.control[1] = (v.control[1] & ~(255u << shift)) | mask << shift;
            ds_check(v, signatures, keys);
        }
    /* Dynamic state and inactive words cannot fragment effective descriptors.
     */
    for (unsigned n = 0; n < 256; n++) {
        NV2AMetalDrawConfig v = c;
        v.control[0] &= ~NV_PGRAPH_CONTROL_0_ZENABLE;
        v.control[0] ^= (n & 7) << 16 | (n & 1) << 24;
        v.control[1] = n << 8;
        v.control[2] = n;
        v.blend_color = n * 0x01010101u;
        v.scissor_enabled = YES;
        v.scissor = (MTLScissorRect){ n % 8, n % 4, 1, 1 };
        v.setup_raster = (n & 1) ? NV_PGRAPH_SETUPRASTER_FRONTFACE : 0;
        ds_check(v, signatures, keys);
    }
    [lru removeAllObjects];
    uint64_t before = [[cache valueForKey:@"buildCount"] unsignedLongLongValue];
    uint64_t evictions = lru.evictionCount;
    __weak id<MTLDepthStencilState> retained = nil;
    @autoreleasepool {
        NV2AMetalDrawState *hot = ds_capture(c);
        retained = hot.depthStencil;
        for (unsigned n = 0; n < 300; n++) {
            NV2AMetalDrawConfig v = c;
            v.control[1] =
                (v.control[1] & 65535) | (n & 255) << 16 | (n / 256) << 24;
            ds_capture(v);
            assert(ds_capture(c).depthStencil == hot.depthStencil);
        }
        assert(lru.count == 256 && lru.evictionCount - evictions == 45);
        assert([[cache valueForKey:@"buildCount"] unsignedLongLongValue] -
                   before ==
               301);
        ds_fail_build = YES;
        NV2AMetalDrawConfig failed = c;
        failed.control[1] = (failed.control[1] & 65535) | 0x12340000u;
        NSError *error = nil;
        assert(![[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                    config:&failed
                                                     error:&error] &&
               error);
        assert(lru.count == 256 && lru.evictionCount - evictions == 45);
        ds_fail_build = NO;
        ds_capture(failed);
        assert(lru.evictionCount - evictions == 46);
        /* Invalid enabled operations still fail before a warmed key lookup. */
        failed.control[2] = 0;
        error = nil;
        uint64_t misses = lru.missCount;
        assert(![[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                                    config:&failed
                                                     error:&error] &&
               error && lru.missCount == misses);
    }
    [lru removeAllObjects];
    /* Concurrent owners share one immutable object and one native request. */
    before = [[cache valueForKey:@"buildCount"] unsignedLongLongValue];
    NSMutableArray *owners = [NSMutableArray new];
    method_setImplementation(lookup, ds_original_lookup);
    dispatch_apply(64, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                   ^(size_t index) {
                     (void)index;
                     NV2AMetalDrawState *r = ds_capture(ds_config());
                     @synchronized(owners) {
                         [owners addObject:r];
                     }
                   });
    assert([[cache valueForKey:@"buildCount"] unsignedLongLongValue] - before ==
           1);
    for (NV2AMetalDrawState *r in owners)
        assert([r valueForKey:@"depthStencilCache"] == cache &&
               r.depthStencil == [owners[0] depthStencil]);
    [owners removeAllObjects];
    method_setImplementation(lookup, (IMP)ds_lookup);
    /* All legacy scalar snapshots reuse the same effective native state. */
    initialize(0, 1);
    state->pgraph.regs_[NV_PGRAPH_CONTROL_0] = c.control[0];
    state->pgraph.regs_[NV_PGRAPH_CONTROL_1] = c.control[1];
    state->pgraph.regs_[NV_PGRAPH_CONTROL_2] = c.control[2];
    NV2AMetalPGRAPHPixelState *p = capture(nil);
    NSData *wire = p.snapshotData;
    before = [[cache valueForKey:@"buildCount"] unsignedLongLongValue];
    for (unsigned version = 1; version <= 6; version++) {
        NSError *error = nil;
        NV2AMetalPGRAPHPixelState *restored = [[NV2AMetalPGRAPHPixelState alloc]
            initWithSnapshot:version == 6 ? wire :
                                            legacy_pixel_fixture(wire, version)
                    textures:nil
                      device:commands.device
                       error:&error];
        require(restored != nil, error);
        assert(restored.raster.depthStencil == p.raster.depthStencil);
    }
    assert([[cache valueForKey:@"buildCount"] unsignedLongLongValue] == before);
    /* Effective descriptor sharing never removes capture attachment guards. */
    NV2AMetalDrawConfig disabled = { 0 };
    NV2AMetalDrawState *withoutDepth = ds_capture(disabled);
    disabled.control[0] = NV_PGRAPH_CONTROL_0_ZENABLE | 7 << 16;
    NV2AMetalDrawState *withDepth = ds_capture(disabled);
    assert(withDepth.depthStencil == withoutDepth.depthStencil &&
           withDepth.requiresDepth && !withoutDepth.requiresDepth);
    for (unsigned which = 0; which < 2; which++) {
        NV2AMetalDrawConfig missing = disabled;
        if (which) {
            missing = c;
            missing.control[0] &= ~NV_PGRAPH_CONTROL_0_ZENABLE;
        }
        NV2AMetalDrawState *r = ds_capture(missing);
        NSError *attachmentError = nil;
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        pass.colorAttachments[0].texture = target(8, 8);
        id<MTLBuffer> vertices =
            [commands.device newBufferWithLength:3 * sizeof(NV2AMetalVertex)
                                         options:MTLResourceStorageModeShared];
        NV2AMetalPixelUniforms u = { 0 };
        NV2AMetalPixelTexture textures[4] = { 0 };
        assert(![shader encodeVertices:vertices
                                 count:3
                             primitive:MTLPrimitiveTypeTriangle
                              uniforms:&u
                              textures:textures
                                  pass:pass
                             drawState:r
                              commands:commands
                                 error:&attachmentError]);
        assert([attachmentError.localizedDescription
                   isEqual:@"Invalid native draw state/attachments"] &&
               !commands.commandBuffer);
    }
    ds_capture(c);
    double times[2][7];
    ds_reference_config = c;
    ds_reference_requests = 0;
    before = [[cache valueForKey:@"buildCount"] unsignedLongLongValue];
    for (unsigned pair = 0; pair < 9; pair++)
        for (unsigned order = 0; order < 2; order++) {
            unsigned mode = (pair + order) & 1;
            ds_uncached = mode;
            double start = ds_clock();
            for (unsigned n = 0; n < 128; n++)
                @autoreleasepool {
                    ds_capture(c);
                }
            if (pair >= 2)
                times[mode][pair - 2] = ds_clock() - start;
        }
    ds_uncached = NO;
    assert([[cache valueForKey:@"buildCount"] unsignedLongLongValue] ==
               before &&
           ds_reference_requests == 9 * 128);
    for (unsigned mode = 0; mode < 2; mode++)
        qsort(times[mode], 7, sizeof(double), ds_time_compare);
    NSError *error = nil;
    NV2AMetalPixelShader *pixelShader = [[NV2AMetalPixelShader alloc]
        initWithDevice:commands.device
           colorFormat:MTLPixelFormatRGBA32Float
           depthFormat:MTLPixelFormatDepth32Float_Stencil8
           sampleCount:1
                 error:&error];
    require(pixelShader != nil, error);
    require([commands beginWithError:&error] != nil, error);
    NSMutableArray *images = [NSMutableArray new];
    for (unsigned n = 0; n < 256; n++) {
        NV2AMetalDrawConfig v = c;
        v.control[0] = (v.control[0] & ~(NV_PGRAPH_CONTROL_0_ZENABLE |
                                         NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                                         NV_PGRAPH_CONTROL_0_ZFUNC)) |
                       ((n & 8) ? NV_PGRAPH_CONTROL_0_ZENABLE : 0) |
                       ((n & 16) ? NV_PGRAPH_CONTROL_0_ZWRITEENABLE : 0) |
                       (n & 7) << 16;
        v.control[1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE |
                       ((n >> 5) & 7) << 4 |
                       ((n & 1) ? 0xff000000u : 0x55000000u) |
                       ((n & 2) ? 0xff0000u : 0xaa0000u);
        v.control[2] =
            (n % 8 + 1) | ((n / 8) % 8 + 1) << 4 | ((n / 32) % 8 + 1) << 8;
        @autoreleasepool {
            [images addObject:@[
                ds_gpu_trace(pixelShader, v, NO),
                ds_gpu_trace(pixelShader, v, YES)
            ]];
        }
    }
    /* Evict every queued state before submission; command slots retain it. */
    [lru removeAllObjects];
    assert(lru.count == 0);
    finish();
    unsigned changedColor = 0, changedDepth = 0, changedStencil = 0;
    for (NSArray *pair in images) {
        float colors[2][8][8][4];
        for (unsigned mode = 0; mode < 2; mode++)
            [pair[mode][0] getBytes:colors[mode]
                        bytesPerRow:128
                         fromRegion:MTLRegionMake2D(0, 0, 8, 8)
                        mipmapLevel:0];
        assert(!memcmp(colors[0], colors[1], sizeof(colors[0])));
        for (unsigned y = 0; y < 8; y++) {
            id<MTLBuffer> depth0 = pair[0][1], depth1 = pair[1][1];
            const uint8_t *d0 = depth0.contents, *d1 = depth1.contents;
            id<MTLBuffer> stencil0 = pair[0][2], stencil1 = pair[1][2];
            const uint8_t *s0 = stencil0.contents, *s1 = stencil1.contents;
            assert(!memcmp(d0 + y * 256, d1 + y * 256, 32) &&
                   !memcmp(s0 + y * 256, s1 + y * 256, 8));
            for (unsigned x = 0; x < 8; x++) {
                changedColor += colors[0][y][x][0] != .125f;
                float z;
                memcpy(&z, d0 + y * 256 + x * 4, 4);
                changedDepth += z != .5f;
                changedStencil += s0[y * 256 + x] != 127;
            }
        }
    }
    assert(changedColor && changedDepth && changedStencil);
    __weak NV2AMetalDrawState *cancelledRaster;
    /* A cancelled recording must release its extra reference as usual. */
    require([commands beginWithError:&error] != nil, error);
    @autoreleasepool {
        NV2AMetalDrawState *r = ds_capture(c);
        retained = r.depthStencil;
        cancelledRaster = r;
        require([commands keepAlive:r error:&error], error);
        [lru removeAllObjects];
    }
    @autoreleasepool {
        assert(retained);
    }
    [commands cancel];
    assert(!cancelledRaster);
    ds_last_descriptor = nil;
    method_setImplementation(lookup, ds_original_lookup);
    method_setImplementation(build, ds_original_build);
    printf("Depth/stencil cache:%u independent effective-descriptor "
           "cases;256-entry pressure,300 cold variants+hot,45 selective "
           "evictions,failed creation/retry,64 concurrent owners,6 legacy "
           "restores PASS\n",
           ds_checked_configs);
    printf("Depth/stencil cache:256 exact color+depth+stencil GPU trace "
           "pairs,1536 draws;all cache entries cleared before submit;cancel "
           "retention PASS\n");
    printf("Depth/stencil cache:128 full captures median "
           "cached/uncached-reference %.6f/%.6f ms;0/128 native state requests "
           "on warmed trace,2 warmups/7 alternating pairs;no "
           "malloc/driver-byte or app measurement\n",
           times[0][3], times[1][3]);
}
#endif
