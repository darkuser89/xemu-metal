/* Offset-aware pending streams through compute and native graphics.
 * No emulator, BIOS, window or app. SPDX-License-Identifier: LGPL-2.0-or-later
 */
#import "hw/xbox/nv2a/pgraph/metal/pending-native.h"
#import "hw/xbox/nv2a/pgraph/metal/geometry.h"
#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"
#import <objc/runtime.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NV2AMetalCommands *commands;
static NV2AMetalGeometry *geometry;
static NV2AMetalPixelShader *pixels[2];
static unsigned computeEncoders, pairs, borrowedStreams, joinedStreams;
static unsigned currentLayout, currentKind, currentPrimitive, currentPolicy;
static uint64_t avoidedBytes, visibleSamples;
static double gpuSeconds;
static BOOL msaaSelf;
static void (*original_feedback)(id, SEL, MTL4CommitFeedbackHandler);
static void feedback(id owner, SEL selector, MTL4CommitFeedbackHandler handler)
{
    original_feedback(owner, selector, ^(id<MTL4CommitFeedback> f) {
      gpuSeconds = f.GPUEndTime - f.GPUStartTime;
      handler(f);
    });
}
static id (*original_compute)(id, SEL);
static id count_compute(id owner, SEL selector)
{
    computeEncoders++;
    return original_compute(owner, selector);
}
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Vertex slices: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static void begin(void)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
}
static void finish(void)
{
    NSError *error = nil;
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
}
static id<MTLBuffer> read_buffer(id<MTLBuffer> source, NSUInteger first,
                                 NSUInteger bytes)
{
    NSError *error = nil;
    id<MTLBuffer> result =
        [commands.device newBufferWithLength:bytes
                                     options:MTLResourceStorageModeShared];
    assert(result && first <= source.length && bytes <= source.length - first);
    require([commands addResource:source error:&error] &&
                [commands addResource:result error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:source
             sourceOffset:first
                 toBuffer:result
        destinationOffset:0
                     size:bytes];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return result;
}
static void upload(id<MTLBuffer> source, id<MTLBuffer> destination)
{
    NSError *error = nil;
    require([commands addResource:source error:&error] &&
                [commands addResource:destination error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:source
             sourceOffset:0
                 toBuffer:destination
        destinationOffset:0
                     size:source.length];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
}
static id<MTLTexture> texture(MTLPixelFormat format, unsigned samples)
{
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:32
                                                          height:32
                                                       mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    if (samples > 1) {
        td.textureType = MTLTextureType2DMultisample;
        td.sampleCount = samples;
    }
    id<MTLTexture> result = [commands.device newTextureWithDescriptor:td];
    assert(result);
    return result;
}
static id<MTLBuffer> read_texture(id<MTLTexture> texture, MTLBlitOption option)
{
    NSError *error = nil;
    id<MTLBuffer> result =
        [commands.device newBufferWithLength:32 * 256
                                     options:MTLResourceStorageModeShared];
    assert(result);
    memset(result.contents, 0xcd, result.length);
    require([commands addResource:texture error:&error] &&
                [commands addResource:result error:&error],
            error);
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
                      sourceSize:MTLSizeMake(32, 32, 1)
                        toBuffer:result
               destinationOffset:0
          destinationBytesPerRow:256
        destinationBytesPerImage:0
                         options:option];
    [e endEncoding];
    return result;
}

@interface SliceFrame : NSObject
@property(nonatomic) NSArray<id<MTLBuffer>> *images, *geometry, *projections;
@property(nonatomic) id<MTLBuffer> query;
@end
@implementation SliceFrame
@end
static NV2AMetalPixelRasterClass raster_class(NV2AMetalGeometryResult *g)
{
    if (g.directTriangles)
        return NV2AMetalPixelRasterDirectTriangle | g.directTriangleOptions;
    if (g.directPoints)
        return NV2AMetalPixelRasterDirectPoint;
    if (g.directLineMode)
        return NV2AMetalPixelRasterDirectLineSmooth + g.directLineMode - 1;
    return g.expandedLines    ? NV2AMetalPixelRasterExpandedLine :
           g.expandedPolygons ? NV2AMetalPixelRasterExpandedPolygon :
                                NV2AMetalPixelRasterNative;
}

static SliceFrame *render(NSArray<id<MTLBuffer>> *buffers,
                          NSArray<NSNumber *> *firsts,
                          NSArray<NSNumber *> *counts, unsigned primitive,
                          unsigned policy)
{
    NSError *error = nil;
    unsigned samples = policy == 2 || policy == 5 ? 4 : 1;
    NV2AMetalGeometryRasterConfig c = {
        .front = policy == 4 ? NV2AMetalPolygonLine :
                 policy == 5 && primitive != NV2AMetalPrimitivePolygon ?
                               NV2AMetalPolygonPoint :
                               NV2AMetalPolygonFill,
        .back = policy == 1 ? NV2AMetalPolygonLine :
                policy == 4 || (policy == 5 &&
                                primitive == NV2AMetalPrimitivePolygon) ?
                              NV2AMetalPolygonLine :
                policy == 5 ? NV2AMetalPolygonPoint :
                              NV2AMetalPolygonFill,
        .frontClockwise = (policy & 1) != 0,
        .cullBack = policy == 2,
        .cullFront = policy == 3,
        .lineWidth = policy == 4 ? 3 : 1,
        .lineSmooth = policy == 4,
        .polygonSmooth = policy == 3,
        .viewportWidth = 32,
        .viewportHeight = 32
    };
    NSMutableArray *groups = [NSMutableArray new], *raw = [NSMutableArray new],
                   *projected = [NSMutableArray new];
    for (NSUInteger i = 0; i < buffers.count; i++) {
        NSArray *gs =
            [geometry encodeNativeRasterVertices:buffers[i]
                                           first:firsts[i].unsignedIntegerValue
                                           count:counts[i].unsignedIntegerValue
                                       primitive:primitive
                                          config:&c
                                          smooth:(policy & 1) == 0
                                  firstProvoking:(policy & 2) != 0
                                    zPerspective:policy == 2 || policy == 4
                                        commands:commands
                                           error:&error];
        require(gs != nil, error);
        [groups addObject:gs];
        for (NV2AMetalGeometryResult *g in gs) {
            if (!g.vertexCount)
                continue;
            [raw
                addObject:read_buffer(g.vertices,
                                      g.firstVertex * sizeof(NV2AMetalVertex),
                                      g.vertexCount * sizeof(NV2AMetalVertex))];
            if (g.polygonProjections)
                [projected addObject:read_buffer(g.polygonProjections, 0,
                                                 g.polygonProjections.length)];
        }
    }
    id<MTLTexture> color = texture(MTLPixelFormatRGBA8Unorm, samples);
    id<MTLTexture> resolve =
        samples == 1 ? color : texture(MTLPixelFormatRGBA8Unorm, 1);
    id<MTLTexture> depth =
        samples == 1 ? texture(MTLPixelFormatDepth32Float_Stencil8, 1) : nil;
    uint64_t initial = 7;
    id<MTLBuffer> query =
        [commands.device newBufferWithBytes:&initial
                                     length:8
                                    options:MTLResourceStorageModeShared];
    require([commands addResource:color error:&error] &&
                [commands addResource:resolve error:&error] &&
                (!depth || [commands addResource:depth error:&error]) &&
                [commands addResource:query error:&error],
            error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].resolveTexture = samples == 1 ? nil : resolve;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction =
        samples == 1 ? MTLStoreActionStore : MTLStoreActionMultisampleResolve;
    if (depth) {
        pass.depthAttachment.texture = depth;
        pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        pass.depthAttachment.clearDepth = 1;
        pass.stencilAttachment.texture = depth;
        pass.stencilAttachment.loadAction = MTLLoadActionClear;
        pass.stencilAttachment.storeAction = MTLStoreActionStore;
        pass.stencilAttachment.clearStencil = 13;
    }
    pass.visibilityResultBuffer = query;
    pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    NV2AMetalDrawConfig config = {
        .control = { NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                         NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE,
                     0, 0 }
    };
    if (depth) {
        config.control[0] |= NV_PGRAPH_CONTROL_0_ZENABLE |
                             NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 3 << 16;
        config.control[1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 7 << 4 |
                            0xff << 16 | 0xffu << 24;
        config.control[2] = 1 | 1 << 4 | 4 << 8;
    }
    if (policy == 1 || policy == 2)
        config.blend = NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8;
    if (policy == 4) {
        config.blend = NV_PGRAPH_BLEND_LOGICOP_ENABLE | 6 << 12;
        config.control[0] &= ~NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE;
    }
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&config
                                             error:&error];
    require(state != nil, error);
    NV2AMetalPixelUniforms u = { 0 };
    u.smooth_shading = (policy & 1) == 0;
    u.two_side = 1;
    u.z_perspective = policy == 2 || policy == 4;
    u.point_sprite = 0;
    u.combiner.final_inputs[0] = policy == 2 ? PS_REGISTER_T3 : PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    u.combiner.shader_stage_program =
        policy == 2 ? PS_TEXTUREMODES_PASSTHRU << 15 : 0;
    u.surface_scale[0] = u.surface_scale[1] = 1;
    u.depth_format = NV2AMetalPixelDepthD16;
    u.depth_offset = .125f;
    u.depth_factor = 2;
    u.clip_range[1] = u.clip_range[3] = 65535;
    u.clip_regions[0][2] = u.clip_regions[0][3] = 32;
    NV2AMetalPixelTexture bindings[4] = { 0 };
    id<MTL4RenderCommandEncoder> e =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    for (NSArray<NV2AMetalGeometryResult *> *gs in groups) {
        BOOL mixed = gs.count > 1 && primitive != NV2AMetalPrimitivePolygon;
        NSUInteger rounds = mixed ? gs[0].primitiveCount : 1;
        for (NSUInteger p = 0; p < rounds; p++)
            for (NV2AMetalGeometryResult *g in gs) {
                if (!g.vertexCount)
                    continue;
                NSUInteger count =
                    mixed ? g.verticesPerPrimitive : g.vertexCount;
                NSUInteger offset =
                    mixed ? p * count * sizeof(NV2AMetalVertex) : 0;
                /* Metal defines point_coord only for point primitives. */
                u.point_sprite = g.primitiveType == MTLPrimitiveTypePoint;
                require([pixels[samples > 1] encodeGeometry:g
                                                     offset:offset
                                                      count:count
                                                   uniforms:&u
                                                   textures:bindings
                                                       pass:pass
                                                  drawState:state
                                                rasterClass:raster_class(g)
                                       ignorePolygonCulling:g.expandedLines ||
                                                            g.expandedPolygons
                                              renderEncoder:e
                                                   commands:commands
                                                      error:&error],
                        error);
            }
    }
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    SliceFrame *frame = [SliceFrame new];
    NSMutableArray *images = [NSMutableArray
        arrayWithObject:read_texture(resolve, MTLBlitOptionNone)];
    if (depth) {
        [images
            addObject:read_texture(depth, MTLBlitOptionDepthFromDepthStencil)];
        [images addObject:read_texture(depth,
                                       MTLBlitOptionStencilFromDepthStencil)];
    }
    frame.images = images;
    frame.geometry = raw;
    frame.projections = projected;
    frame.query = query;
    return frame;
}

static NV2AMetalPendingInput *input(unsigned kind, unsigned stream,
                                    unsigned count)
{
    if (kind == NV2AMetalInputArrays)
        return [NV2AMetalPendingInput arraysFrom:stream * 128 count:count];
    if (kind == NV2AMetalInputIndexed) {
        uint32_t indices[16];
        for (unsigned i = 0; i < count; i++)
            indices[i] = i + stream * 128;
        return [NV2AMetalPendingInput indexed:[NSData dataWithBytes:indices
                                                             length:count * 4]];
    }
    return [NV2AMetalPendingInput inlineKind:kind count:count];
}
static void compare_buffers(NSArray<id<MTLBuffer>> *a,
                            NSArray<id<MTLBuffer>> *b, const char *label)
{
    assert(a.count == b.count);
    for (NSUInteger i = 0; i < a.count; i++) {
        assert(a[i].length == b[i].length);
        if (memcmp(a[i].contents, b[i].contents, a[i].length)) {
            const uint32_t *left = a[i].contents, *right = b[i].contents;
            for (NSUInteger word = 0; word < a[i].length / 4; word++)
                if (left[word] != right[word]) {
                    fprintf(stderr,
                            "%s layout%u kind%u primitive%u policy%u buffer%lu "
                            "word%lu %08x/%08x\n",
                            label, currentLayout, currentKind, currentPrimitive,
                            currentPolicy, (unsigned long)i,
                            (unsigned long)word, left[word], right[word]);
                    break;
                }
            abort();
        }
    }
}
static void fixture(unsigned layout, unsigned kind,
                    NV2AMetalVertex source[2][96])
{
    NSError *error = nil;
    currentLayout = layout;
    currentKind = kind;
    id<MTLBuffer> uploads[2], buffers[2];
    for (unsigned s = 0; s < 2; s++) {
        uploads[s] =
            [commands.device newBufferWithBytes:source[s]
                                         length:sizeof(source[s])
                                        options:MTLResourceStorageModeShared];
        buffers[s] =
            [commands.device newBufferWithLength:sizeof(source[s])
                                         options:MTLResourceStorageModePrivate];
        assert(uploads[s] && buffers[s]);
    }
    NV2AMetalPendingJournal *journal =
        [[NV2AMetalPendingJournal alloc] initWithLimit:128];
    NSMutableArray *expected[2] = { [NSMutableArray new],
                                    [NSMutableArray new] };
    NSMutableData *bytes[2] = { [NSMutableData new], [NSMutableData new] };
    NV2AMetalPendingUpdate *update = nil;
    unsigned parts = layout >= 1 && layout <= 4 ? 2 : 1, total = 0;
    for (unsigned part = 0; part < parts; part++) {
        unsigned count = layout == 6 ? 11 : parts == 1 ? 12 : part == 0 ? 4 : 8;
        total += count;
        NSMutableArray *inputs = [NSMutableArray new],
                       *suffixes = [NSMutableArray new];
        for (unsigned s = 0; s < 2; s++) {
            unsigned first = layout == 5 ? 0 :
                             layout == 6 ? 80 + s * 2 :
                             layout == 3 ? (part ? 1 : 9) + s * 2 :
                             layout == 2 ? (part ? 9 : 1) + s * 2 :
                             layout == 4 ? (part ? 17 : 5) + s * 2 :
                             layout == 1 ? 3 + part * 4 + s * 2 :
                                           1 + s * 2;
            unsigned which = layout == 4 ? (s + part) % 2 : s;
            NV2AMetalPendingSpan *span =
                [NV2AMetalPendingSpan resource:buffers[which]
                                         first:first
                                         count:count];
            assert(span);
            [expected[s] addObject:span];
            [bytes[s] appendBytes:source[which] + first
                           length:count * sizeof(NV2AMetalVertex)];
            [inputs addObject:input(kind, s, total)];
            [suffixes addObject:span];
        }
        NV2AMetalPendingPlan *plan = [journal planInputs:inputs
                                     preservingLastArray:NO
                                                   error:&error];
        require(plan != nil, error);
        update = [journal preparePlan:plan suffixes:suffixes error:&error];
        require(update && [journal commitUpdate:update error:&error], error);
    }
    NV2AMetalPendingNative *native =
        [[NV2AMetalPendingNative alloc] initWithUpdate:update
                                                device:commands.device
                                                 limit:128
                                                 error:&error];
    require(native != nil, error);
    BOOL uploaded = NO;
    for (unsigned primitive = 1; primitive <= 10; primitive++)
        for (unsigned policy = 0; policy < 6; policy++) {
            if (msaaSelf && (primitive != 3 || policy != 2))
                continue;
            @autoreleasepool {
                currentPrimitive = primitive;
                currentPolicy = policy;
                begin();
                if (!uploaded) {
                    for (unsigned s = 0; s < 2; s++)
                        upload(uploads[s], buffers[s]);
                    uploaded = YES;
                }
                unsigned before = computeEncoders;
                NSArray<NV2AMetalVertexSlice *> *slices =
                    [native encodeSlicesWithCommands:commands error:&error];
                require(slices != nil, error);
                unsigned sliceEncoders = computeEncoders - before;
                before = computeEncoders;
                NSArray<id<MTLBuffer>> *joined =
                    [native encodeWithCommands:commands error:&error];
                require(joined != nil, error);
                unsigned legacyEncoders = computeEncoders - before;
                BOOL borrow =
                    layout == 0 || layout == 1 || layout == 5 || layout == 6;
                assert(sliceEncoders == (borrow ? 0u : 2u));
                assert(legacyEncoders == (layout == 5 ? 0u : 2u));
                NSMutableArray *newBuffers = [NSMutableArray new],
                               *newFirsts = [NSMutableArray new];
                NSMutableArray *reads = [NSMutableArray new],
                               *archives = [NSMutableArray new];
                for (unsigned s = 0; s < 2; s++) {
                    NV2AMetalVertexSlice *slice = slices[s];
                    assert(slice.vertexCount == total);
                    NV2AMetalPendingSpan *first = expected[s][0];
                    assert((slice.buffer == first.resource) == borrow);
                    assert(slice.firstVertex == (borrow ? first.first : 0));
                    [newBuffers addObject:slice.buffer];
                    [newFirsts addObject:@(slice.firstVertex)];
                    [reads
                        addObject:read_buffer(slice.buffer,
                                              slice.firstVertex *
                                                  sizeof(NV2AMetalVertex),
                                              total * sizeof(NV2AMetalVertex))];
                    if (borrow)
                        borrowedStreams++;
                    else
                        joinedStreams++;
                    if (borrow && first.first)
                        avoidedBytes += total * sizeof(NV2AMetalVertex);
                    if (primitive == 1 && policy == 0) {
                        NV2AMetalVertexStream *stream =
                            [[NV2AMetalVertexStream alloc]
                                initWithDevice:commands.device
                                         limit:128
                                         error:&error];
                        require(stream != nil, error);
                        for (NV2AMetalPendingSpan *span in expected[s])
                            require([stream appendVertices:span.resource
                                                     first:span.first
                                                     count:span.count
                                                     error:&error],
                                    error);
                        id<MTLBuffer> packed =
                            [stream encodeWithCommands:commands error:&error];
                        require(packed != nil, error);
                        assert(packed.length == bytes[s].length);
                        [archives
                            addObject:read_buffer(packed, 0, packed.length)];
                    }
                }
                SliceFrame *a = render(
                    msaaSelf || getenv("SLICE_BASELINE_REPEAT") ? joined :
                                                                  newBuffers,
                    msaaSelf || getenv("SLICE_BASELINE_REPEAT") ? @[ @0, @0 ] :
                                                                  newFirsts,
                    native.counts, primitive, policy);
                SliceFrame *b = render(joined, @[ @0, @0 ], native.counts,
                                       primitive, policy);
                finish();
                for (unsigned s = 0; s < 2; s++) {
                    assert(!memcmp(((id<MTLBuffer>)reads[s]).contents,
                                   bytes[s].bytes, bytes[s].length));
                    if (archives.count)
                        assert(!memcmp(((id<MTLBuffer>)archives[s]).contents,
                                       bytes[s].bytes, bytes[s].length));
                }
                compare_buffers(a.geometry, b.geometry, "geometry");
                assert(a.projections.count == b.projections.count);
                for (NSUInteger n = 0; n < a.projections.count; n++) {
                    id<MTLBuffer> left = a.projections[n],
                                  right = b.projections[n];
                    assert(left.length == right.length);
                    const NV2AMetalPolygonProjection *x = left.contents,
                                                     *y = right.contents;
                    for (NSUInteger j = 0; j < left.length / sizeof(*x); j++) {
                        assert(x[j].count == y[j].count && x[j].count <= 8);
                        assert(!memcmp(x[j].points, y[j].points,
                                       x[j].count * 2 * sizeof(float)));
                    }
                }
                compare_buffers(a.images, b.images, "images");
                assert(*(uint64_t *)a.query.contents ==
                       *(uint64_t *)b.query.contents);
                visibleSamples += *(uint64_t *)a.query.contents - 7;
                pairs++;
            }
        }
}
static int compare_time(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static void benchmark(unsigned count)
{
    NSError *error = nil;
    NSUInteger length = (count + 32) * sizeof(NV2AMetalVertex);
    id<MTLBuffer> source =
        [commands.device newBufferWithLength:length
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> private =
        [commands.device newBufferWithLength:length
                                     options:MTLResourceStorageModePrivate];
    assert(source && private);
    uint32_t *words = source.contents;
    for (NSUInteger i = 0; i < length / 4; i++)
        words[i] = 0x3e000000u + i * 31u;
    begin();
    upload(source, private);
    finish();
    NV2AMetalVertexStream *stream =
        [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                limit:count
                                                error:&error];
    require(stream != nil, error);
    require([stream appendVertices:private
                             first:17
                             count:count / 2
                             error:&error] &&
                [stream appendVertices:private
                                 first:17 + count / 2
                                 count:count / 2
                                 error:&error],
            error);
    double times[2][9];
    for (unsigned pair = 0; pair < 11; pair++)
        for (unsigned order = 0; order < 2; order++) {
            @autoreleasepool {
                BOOL copied = (pair + order) & 1;
                begin();
                unsigned before = computeEncoders;
                id<MTLBuffer> buffer;
                NSUInteger first;
                if (copied) {
                    buffer = [stream encodeForDrawingWithCommands:commands
                                                            error:&error];
                    first = 0;
                    assert(buffer != private);
                } else {
                    NV2AMetalVertexSlice *slice =
                        [stream encodeSliceForDrawingWithCommands:commands
                                                            error:&error];
                    require(slice != nil, error);
                    buffer = slice.buffer;
                    first = slice.firstVertex;
                    assert(buffer == private && first == 17 &&
                           slice.vertexCount == count);
                }
                require(buffer != nil, error);
                id<MTLBuffer> result =
                    read_buffer(buffer, first * sizeof(NV2AMetalVertex),
                                count * sizeof(NV2AMetalVertex));
                assert(computeEncoders - before == (copied ? 2u : 1u));
                finish();
                assert(!memcmp(result.contents,
                               (char *)source.contents +
                                   17 * sizeof(NV2AMetalVertex),
                               result.length));
                assert(gpuSeconds > 0);
                if (pair >= 2)
                    times[copied][pair - 2] = gpuSeconds;
            }
        }
    for (unsigned i = 0; i < 2; i++)
        qsort(times[i], 9, sizeof(double), compare_time);
    printf("Metal4 vertex slice benchmark:%u vertices/two adjacent spans "
           "at17,22 exact GPU byte outputs,"
           "2 warmups/9 alternating samples;assembly+identical GPU blit "
           "consumer borrowed/join %.6f/%.6fms;"
           "0/1 assembly encoders,%zu join bytes avoided PASS\n",
           count, times[0][4] * 1000, times[1][4] * 1000,
           (size_t)(count * sizeof(NV2AMetalVertex)));
}

static void bounds_and_lifetime(void)
{
    NSError *error = nil;
    __weak id<MTLBuffer> weakSource;
    id<MTLBuffer> result;
    for (unsigned cancel = 0; cancel < 2; cancel++) {
        begin();
        @autoreleasepool {
            uint32_t data[16 * sizeof(NV2AMetalVertex) / 4];
            for (unsigned i = 0; i < sizeof(data) / 4; i++)
                data[i] = 0x3e000000u + i;
            id<MTLBuffer> source = [commands.device
                newBufferWithBytes:data
                            length:sizeof(data)
                           options:MTLResourceStorageModeShared];
            assert(source);
            weakSource = source;
            NV2AMetalVertexStream *stream =
                [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                        limit:16
                                                        error:&error];
            require(stream != nil, error);
            require([stream appendVertices:source first:3 count:7 error:&error],
                    error);
            NV2AMetalVertexSlice *slice =
                [stream encodeSliceForDrawingWithCommands:commands
                                                    error:&error];
            require(slice != nil, error);
            result = read_buffer(slice.buffer,
                                 slice.firstVertex * sizeof(NV2AMetalVertex),
                                 slice.vertexCount * sizeof(NV2AMetalVertex));
            memset(result.contents, 0xa5, result.length);
        }
        assert(weakSource);
        if (cancel)
            [commands cancel];
        else
            finish();
        assert(!weakSource);
        if (cancel) {
            for (NSUInteger i = 0; i < result.length; i++)
                assert(((uint8_t *)result.contents)[i] == 0xa5);
        } else {
            const uint32_t *data = result.contents;
            for (NSUInteger i = 0; i < result.length / 4; i++)
                assert(data[i] ==
                       0x3e000000u + 3 * sizeof(NV2AMetalVertex) / 4 + i);
        }
    }
    id<MTLBuffer> source =
        [commands.device newBufferWithLength:16 * sizeof(NV2AMetalVertex)
                                     options:MTLResourceStorageModeShared];
    assert(source);
    NV2AMetalVertexStream *stream =
        [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                limit:16
                                                error:&error];
    require(stream != nil, error);
    require([stream appendVertices:source first:3 count:7 error:&error], error);
    assert(![stream encodeSliceForDrawingWithCommands:commands error:&error]);
    begin();
    unsigned before = computeEncoders, rejected = 1;
    NV2AMetalGeometryRasterConfig c = { .lineWidth = 1,
                                        .viewportWidth = 32,
                                        .viewportHeight = 32 };
    const NSUInteger firsts[] = { NSUIntegerMax, 17, 16, 15 };
    const NSUInteger counts[] = { 1, 0, 1, 2 };
    for (unsigned i = 0; i < 4; i++) {
        assert(![geometry encodeNativeRasterVertices:source
                                               first:firsts[i]
                                               count:counts[i]
                                           primitive:NV2AMetalPrimitivePoints
                                              config:&c
                                              smooth:YES
                                      firstProvoking:NO
                                        zPerspective:NO
                                            commands:commands
                                               error:&error]);
        rejected++;
    }
    NSArray<NV2AMetalGeometryResult *> *empty =
        [geometry encodeNativeRasterVertices:source
                                       first:16
                                       count:0
                                   primitive:NV2AMetalPrimitivePoints
                                      config:&c
                                      smooth:YES
                              firstProvoking:NO
                                zPerspective:NO
                                    commands:commands
                                       error:&error];
    require(empty != nil, error);
    assert(!empty[0].vertexCount && !empty[0].firstVertex &&
           !empty[0].vertices);
    NSArray<NV2AMetalGeometryResult *> *gs =
        [geometry encodeNativeRasterVertices:source
                                       first:3
                                       count:7
                                   primitive:NV2AMetalPrimitivePoints
                                      config:&c
                                      smooth:YES
                              firstProvoking:NO
                                zPerspective:NO
                                    commands:commands
                                       error:&error];
    require(gs != nil, error);
    NV2AMetalGeometryResult *g = gs[0];
    NV2AMetalPixelUniforms u = { 0 };
    u.surface_scale[0] = u.surface_scale[1] = 1;
    u.clip_range[1] = u.clip_range[3] = 65535;
    u.depth_format = NV2AMetalPixelDepthD16;
    NV2AMetalPixelTexture bindings[4] = { 0 };
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = texture(MTLPixelFormatRGBA8Unorm, 4);
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    NV2AMetalDrawConfig config = {
        .control = { NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE, 0, 0 }
    };
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&config
                                             error:&error];
    require(state != nil, error);
    for (unsigned i = 0; i < 5; i++) {
        NSUInteger offset = 0;
        if (i == 0)
            [g setValue:@(NSUIntegerMax) forKey:@"firstVertex"];
        if (i == 1)
            [g setValue:@17 forKey:@"vertexCount"];
        if (i == 2)
            offset = 1;
        if (i == 3)
            offset = 7 * sizeof(NV2AMetalVertex);
        if (i == 4)
            [g setValue:@YES forKey:@"expandedPolygons"];
        assert(![pixels[1] encodeGeometry:g
                                   offset:offset
                                    count:7
                                 uniforms:&u
                                 textures:bindings
                                     pass:pass
                                drawState:state
                              rasterClass:NV2AMetalPixelRasterDirectPoint
                     ignorePolygonCulling:NO
                            renderEncoder:nil
                                 commands:commands
                                    error:&error]);
        rejected++;
        [g setValue:@3 forKey:@"firstVertex"];
        [g setValue:@7 forKey:@"vertexCount"];
        [g setValue:@NO forKey:@"expandedPolygons"];
    }
    assert(computeEncoders == before);
    [commands cancel];
    begin();
    NV2AMetalVertexSlice *retry =
        [stream encodeSliceForDrawingWithCommands:commands error:&error];
    require(retry != nil, error);
    assert(retry.buffer == source && retry.firstVertex == 3);
    finish();
    printf("Metal4 vertex slice bounds:%u pre-encode rejections,empty end "
           "slice,owner release after GPU completion/cancel,"
           "no cancelled writes,and retry PASS\n",
           rejected);
}

#include "test-metal-msaa-blend.h"

int main(int argc, char **argv)
{
    msaaSelf = argc == 2 && !strcmp(argv[1], "--msaa-self");
    BOOL blendOnly = argc == 2 && !strcmp(argv[1], "--blend-oracle");
    assert(argc == 1 || msaaSelf || blendOnly);
    @autoreleasepool {
        NSError *error = nil;
        commands = [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        geometry = [[NV2AMetalGeometry alloc] initWithDevice:commands.device
                                                       error:&error];
        pixels[0] = [[NV2AMetalPixelShader alloc]
            initWithDevice:commands.device
               colorFormat:MTLPixelFormatRGBA8Unorm
               depthFormat:MTLPixelFormatDepth32Float_Stencil8
               sampleCount:1
                     error:&error];
        pixels[1] = [[NV2AMetalPixelShader alloc]
            initWithDevice:commands.device
               colorFormat:MTLPixelFormatRGBA8Unorm
               depthFormat:MTLPixelFormatInvalid
               sampleCount:4
                     error:&error];
        require(geometry && pixels[0] && pixels[1], error);
        begin();
        Class cls = object_getClass(commands.commandBuffer);
        SEL selector = @selector(computeCommandEncoder);
        Method method = class_getInstanceMethod(cls, selector);
        assert(method);
        class_addMethod(cls, selector, method_getImplementation(method),
                        method_getTypeEncoding(method));
        method = class_getInstanceMethod(cls, selector);
        original_compute =
            (void *)method_setImplementation(method, (IMP)count_compute);
        [commands cancel];
        Method fm = class_getInstanceMethod(MTL4CommitOptions.class,
                                            @selector(addFeedbackHandler:));
        assert(fm);
        original_feedback = (void *)method_setImplementation(fm, (IMP)feedback);
        if (!msaaSelf)
            msaa_blend_oracle();
        if (blendOnly)
            return 0;
        if (!msaaSelf) {
            bounds_and_lifetime();
            benchmark(256);
            benchmark(32768);
        }
        NV2AMetalVertex source[2][96] = { 0 };
        for (unsigned s = 0; s < 2; s++)
            for (unsigned i = 0; i < 96; i++) {
                NV2AMetalVertex *v = &source[s][i];
                unsigned corner = i % 3;
                if ((i / 3) & 1)
                    corner = 2 - corner;
                float x = 2 + (i / 3 % 3) * 8 + (corner == 1 ? 7 : 0);
                float y = 2 + (i / 9 % 3) * 8 + (corner == 2 ? 7 : 0);
                float w = (float[]){ .5f, 1, 2 }[i % 3];
                v->clip[0] = (x / 16 - 1) * w;
                v->clip[1] = (1 - y / 16) * w;
                v->clip[2] = .5f * w;
                v->clip[3] = w;
                v->screen[0] = x;
                v->screen[1] = y;
                v->screen[2] = 2000 + i * 100;
                v->screen[3] = w;
                v->point_size = 1 + i % 3;
                v->fog = i / 128.f;
                v->face = NV2AMetalFaceBack;
                v->slope = 999;
                for (unsigned k = 0; k < 4; k++) {
                    v->color[0][k] = k == 3 ? .75f : ((i + s) >> k) & 1;
                    v->color[2][k] = k == 3 ? .5f : 1 - v->color[0][k];
                    v->texcoord[3][k] = (i + s + k) % 7 / 8.f;
                    for (unsigned row = 0; row < 3; row++)
                        v->plane[row][k] = 100 + row + k;
                }
            }
        if (msaaSelf) {
            for (unsigned repeat = 0; repeat < 16; repeat++)
                fixture(0, 1, source);
            assert(pairs == 16);
            puts("Metal4 MSAA:16 strict same-reference geometry/image/query "
                 "pairs PASS");
        } else if (!getenv("SLICE_BENCHMARK_ONLY"))
            for (unsigned layout = 0; layout < 7; layout++)
                for (unsigned kind = 1; kind <= 4; kind++)
                    @autoreleasepool {
                        fixture(layout, kind, source);
                    }
        method_setImplementation(method, (IMP)original_compute);
        method_setImplementation(fm, (IMP)original_feedback);
        assert(msaaSelf || getenv("SLICE_BENCHMARK_ONLY") ||
               (pairs == 1680 && visibleSamples > 100000));
        if (!msaaSelf && !getenv("SLICE_BENCHMARK_ONLY"))
            printf("Metal4 %s:%u exact "
                   "geometry/color/depth/stencil/query pairs;"
                   "two independent streams,all10 topologies/six raster "
                   "policies/four input kinds/seven layouts;"
                   "%u borrowed/%u GPU-joined streams,%llu old join bytes "
                   "avoided,%llu visible samples;"
                   "56 exact bounded snapshot copies PASS\n",
                   getenv("SLICE_BASELINE_REPEAT") ?
                       "reference self comparison" :
                       "vertex slices",
                   pairs, borrowedStreams, joinedStreams,
                   (unsigned long long)avoidedBytes,
                   (unsigned long long)visibleSamples);
    }
    return 0;
}
