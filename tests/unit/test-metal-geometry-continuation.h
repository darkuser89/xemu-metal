/* Geometry handoff across an actual submitted Surface recording.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_GEOMETRY_CONTINUATION_H
#define TEST_METAL_GEOMETRY_CONTINUATION_H
#import "hw/xbox/nv2a/pgraph/metal/geometry.h"
#import "hw/xbox/nv2a/pgraph/metal/vertex-stream.h"
#import "hw/xbox/nv2a/pgraph/metal/shader-library.h"

@interface NV2AMetalGeometry (GeometryContinuationTest)
- (BOOL)canHandoffNativeRasterGeometry;
@end
typedef struct GeometryContinuationNativeWork {
    BOOL reference;
    NSUInteger buffers, uploads, encoders, dispatches, waits;
} GeometryContinuationNativeWork;
static _Thread_local GeometryContinuationNativeWork *gct_work;
static _Thread_local unsigned gct_fail_buffer, gct_fail_upload,
    gct_fail_encoder, gct_fail_function;
static _Thread_local unsigned gct_fail_ticket, gct_fail_clone;
static NSError *gct_failure;
static BOOL (*gct_admission_original)(id, SEL);
static id (*gct_encoder_original)(id, SEL);
static void (*gct_dispatch_original)(id, SEL, MTLSize, MTLSize);
static id (*gct_upload_original)(id, SEL, const void *, NSUInteger,
                                 NSUInteger *, NSError **);
static BOOL (*gct_wait_original)(id, SEL, NSError **);
static id (*gct_function_original)(id, SEL, NSString *, NSError **);
static BOOL gct_admission(id object, SEL selector)
{
    return !(gct_work && gct_work->reference) &&
           gct_admission_original(object, selector);
}
static id gct_encoder(id object, SEL selector)
{
    if (gct_work)
        gct_work->encoders++;
    if (gct_work && gct_fail_encoder) {
        gct_fail_encoder--;
        return nil;
    }
    return gct_encoder_original(object, selector);
}
static void gct_dispatch(id object, SEL selector, MTLSize grid, MTLSize group)
{
    if (gct_work)
        gct_work->dispatches++;
    gct_dispatch_original(object, selector, grid, group);
}
static id gct_upload(id object, SEL selector, const void *bytes,
                     NSUInteger length, NSUInteger *offset, NSError **error)
{
    if (gct_work)
        gct_work->uploads++;
    if (gct_work && gct_fail_upload) {
        gct_fail_upload--;
        if (error)
            *error = gct_failure;
        return nil;
    }
    return gct_upload_original(object, selector, bytes, length, offset, error);
}
static id gct_function(id object, SEL selector, NSString *name, NSError **error)
{
    if (gct_work && gct_fail_function) {
        gct_fail_function--;
        if (error)
            *error = gct_failure;
        return nil;
    }
    return gct_function_original(object, selector, name, error);
}
static BOOL gct_wait(id object, SEL selector, NSError **error)
{
    if (gct_work)
        gct_work->waits++;
    return gct_wait_original(object, selector, error);
}
@interface NSObject (GeometryContinuationBufferFactory)
- (id<MTLBuffer>)gct_newBufferWithLength:(NSUInteger)length
                                 options:(MTLResourceOptions)options
    __attribute__((objc_method_family(new)));
@end
@implementation NSObject (GeometryContinuationBufferFactory)
- (id<MTLBuffer>)gct_newBufferWithLength:(NSUInteger)length
                                 options:(MTLResourceOptions)options
{
    if (gct_work)
        gct_work->buffers++;
    if (gct_work && gct_fail_buffer) {
        gct_fail_buffer--;
        return nil;
    }
    return [self gct_newBufferWithLength:length options:options];
}
@end
@interface NV2AMetalGeometryContinuation (GeometryContinuationFailure)
- (instancetype)gct_initWithResults:(NSArray *)results
                       surfaceCache:(NV2AMetalSurfaceCache *)cache
                           commands:(NV2AMetalCommands *)commands
    __attribute__((objc_method_family(init)));
@end
@implementation NV2AMetalGeometryContinuation (GeometryContinuationFailure)
- (instancetype)gct_initWithResults:(NSArray *)results
                       surfaceCache:(NV2AMetalSurfaceCache *)cache
                           commands:(NV2AMetalCommands *)commands
{
    NV2AMetalGeometryContinuation *result = [self gct_initWithResults:results
                                                         surfaceCache:cache
                                                             commands:commands];
    if (result && gct_work && gct_fail_ticket) {
        gct_fail_ticket--;
        result = nil;
    }
    return result;
}
@end
@interface NV2AMetalGeometryResult (GeometryContinuationFailure)
- (instancetype)gct_initWithContinuationResult:(NV2AMetalGeometryResult *)result
    __attribute__((objc_method_family(init)));
@end
@implementation NV2AMetalGeometryResult (GeometryContinuationFailure)
- (instancetype)gct_initWithContinuationResult:
    (NV2AMetalGeometryResult *)original
{
    NV2AMetalGeometryResult *result =
        [self gct_initWithContinuationResult:original];
    if (result && gct_work && gct_fail_clone) {
        gct_fail_clone--;
        result = nil;
    }
    return result;
}
@end
@interface GCTInput : NSObject
@property(nonatomic) id<MTLBuffer> buffer;
@property(nonatomic) NV2AMetalIndexedVertices *owner;
@property(nonatomic) NV2AMetalVertexSlice *slice;
@end
@implementation GCTInput
@end
static NV2AMetalGeometryRasterConfig gct_config(unsigned kind)
{
    return (NV2AMetalGeometryRasterConfig){
        .front = kind == 2 ? NV2AMetalPolygonPoint : NV2AMetalPolygonFill,
        .back = kind == 2 || kind == 4 ? NV2AMetalPolygonLine :
                                         NV2AMetalPolygonFill,
        .frontClockwise = YES,
        .lineWidth = 3,
        .lineSmooth = YES,
        .polygonSmooth = kind >= 3,
        .viewportWidth = 32,
        .viewportHeight = 32
    };
}
static enum NV2AMetalPrimitive gct_primitive(unsigned kind)
{
    return kind < 2  ? NV2AMetalPrimitiveLineStrip :
           kind == 2 ? NV2AMetalPrimitiveTriangleStrip :
           kind == 3 ? NV2AMetalPrimitiveQuads :
                       NV2AMetalPrimitivePolygon;
}
static GCTInput *gct_input(NV2AMetalCommands *q, unsigned kind)
{
    NSError *error = nil;
    NV2AMetalVertex v[10] = { 0 };
    const float xy[8][2] = { { 4.5, 4.5 },   { 27.5, 4.5 }, { 27.5, 27.5 },
                             { 4.5, 27.5 },  { 16.5, 3.5 }, { 29.5, 16.5 },
                             { 16.5, 29.5 }, { 3.5, 16.5 } };
    for (unsigned i = 0; i < 10; i++) {
        float w = .75f + (i % 4) * .25f;
        v[i].clip[0] = (xy[i % 8][0] / 16 - 1) * w;
        v[i].clip[1] = (1 - xy[i % 8][1] / 16) * w;
        v[i].clip[2] = .5f * w;
        v[i].clip[3] = w;
        v[i].screen[0] = xy[i % 8][0];
        v[i].screen[1] = xy[i % 8][1];
        v[i].screen[2] = 9000 + (i % 8) * (i % 8) * 600;
        v[i].screen[3] = w;
        v[i].fog = .125f * i;
        v[i].point_size = 3;
        for (unsigned k = 0; k < 4; k++) {
            v[i].color[0][k] = k == 3 ? .75f : (i + k) % 5 / 4.f;
            v[i].color[2][k] = k == 3 ? .5f : (i + 2 * k) % 7 / 6.f;
            for (unsigned t = 0; t < 4; t++)
                v[i].texcoord[t][k] = k == 3 ? 1 : .125f * (i + k + t);
        }
    }
    GCTInput *input = [GCTInput new];
    input.buffer = [q.device newBufferWithBytes:v
                                         length:sizeof(v)
                                        options:MTLResourceStorageModeShared];
    require(input.buffer != nil, nil);
    NV2AMetalVertexStream *stream =
        [[NV2AMetalVertexStream alloc] initWithDevice:q.device
                                                limit:16
                                                error:&error];
    NSUInteger first = 2, count = kind == 3 ? 4 : kind == 4 ? 5 : 6;
    if (kind == 1 || kind == 4) {
        const uint32_t map[] = { 8, 9, 2, 0, 3, 1, 6, 4, 7, 5 };
        input.owner = [[NV2AMetalIndexedVertices alloc]
            initWithVertices:input.buffer
               physicalCount:10
                       remap:[NSData dataWithBytes:map length:sizeof(map)]
                       error:&error];
        require(input.owner && [stream appendIndexedVertices:input.owner
                                                       first:first
                                                       count:count
                                                       error:&error],
                error);
    } else
        require([stream appendVertices:input.buffer
                                 first:first
                                 count:count
                                 error:&error],
                error);
    input.slice = [stream encodeSliceForDrawingWithCommands:q error:&error];
    require(input.slice != nil, error);
    return input;
}
static NSArray *gct_encode(NV2AMetalGeometry *engine, GCTInput *input,
                           unsigned kind, NV2AMetalSurfaceCache *cache,
                           GeometryContinuationNativeWork *work,
                           NV2AMetalGeometryContinuation **ticket,
                           NSError **error)
{
    NV2AMetalGeometryRasterConfig config = gct_config(kind);
    gct_work = work;
    @try {
        return [engine encodeNativeRasterSlice:input.slice
                                     primitive:gct_primitive(kind)
                                        config:&config
                                        smooth:NO
                                firstProvoking:YES
                                  zPerspective:YES
                                      commands:cache.commands
                                  surfaceCache:cache
                                  continuation:ticket
                                         error:error];
    } @finally {
        gct_work = NULL;
    }
}
static NSArray *gct_continue(NV2AMetalGeometry *engine,
                             NV2AMetalGeometryContinuation *ticket,
                             NV2AMetalSurfaceCache *cache,
                             GeometryContinuationNativeWork *work)
{
    gct_work = work;
    @try {
        return [engine continueNativeRasterGeometry:ticket
                                       surfaceCache:cache
                                           commands:cache.commands];
    } @finally {
        gct_work = NULL;
    }
}
static id<MTLBuffer> gct_read(NV2AMetalCommands *q, id<MTLBuffer> source)
{
    NSError *error = nil;
    id<MTLBuffer> out =
        [q.device newBufferWithLength:source.length
                              options:MTLResourceStorageModeShared];
    require(out && [q addResource:source error:&error] &&
                [q addResource:out error:&error],
            error);
    memset(out.contents, 0xcd, out.length);
    id<MTL4ComputeCommandEncoder> e = [q.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:source
             sourceOffset:0
                 toBuffer:out
        destinationOffset:0
                     size:source.length];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return out;
}
static NSArray *gct_collect(NV2AMetalCommands *q,
                            NSArray<NV2AMetalGeometryResult *> *results)
{
    NSMutableArray *reads = [NSMutableArray new];
    for (NV2AMetalGeometryResult *g in results) {
        NSMutableArray *one = [NSMutableArray new];
        for (id b in @[
                 (id)g.vertices ?: NSNull.null,
                 (id)g.indexedVertices.indices ?: NSNull.null,
                 (id)g.lineCoverage ?: NSNull.null,
                 (id)g.polygonCoverage ?: NSNull.null,
                 (id)g.polygonProjections ?: NSNull.null,
                 (id)g.polygonFacing ?: NSNull.null
             ])
            [one addObject:b == NSNull.null ? (id)NSNull.null :
                                             (id)gct_read(q, b)];
        [reads addObject:one];
    }
    return reads;
}
static NSArray *gct_result_bytes(NSArray<NV2AMetalGeometryResult *> *results,
                                 NSArray *reads)
{
    NSMutableArray *bytes = [NSMutableArray new];
    for (NSUInteger i = 0; i < results.count; i++) {
        NV2AMetalGeometryResult *g = results[i];
        NSUInteger metadata[] = { g.vertexCount,           g.sourceVertexCount,
                                  g.physicalVertexCount,   g.indexOffset,
                                  g.firstVertex,           g.primitiveType,
                                  g.polygonMode,           g.primitiveCount,
                                  g.verticesPerPrimitive,  g.expandedLines,
                                  g.expandedPolygons,      g.compactLines,
                                  g.compactPolygons,       g.sourcePrimitive,
                                  g.directPoints,          g.directTriangles,
                                  g.directTriangleOptions, g.directQuadOptions,
                                  g.directPolygonOptions,  g.directLineMode,
                                  g.directLineOptions };
        [bytes addObject:[NSData dataWithBytes:metadata
                                        length:sizeof(metadata)]];
        for (unsigned j = 0; j < 6; j++) {
            id<MTLBuffer> b = reads[i][j];
            if ((id)b == NSNull.null) {
                [bytes addObject:[NSData data]];
                continue;
            }
            if (j == 4) {
                assert(b.length % sizeof(NV2AMetalPolygonProjection) == 0);
                const NV2AMetalPolygonProjection *p = b.contents;
                NSMutableData *defined = [NSMutableData new];
                for (NSUInteger n = 0; n < b.length / sizeof(*p); n++) {
                    assert(p[n].count <= 8);
                    [defined appendBytes:&p[n].count length:4];
                    [defined appendBytes:p[n].points
                                  length:p[n].count * sizeof(p[n].points[0])];
                }
                [bytes addObject:defined];
            } else
                [bytes addObject:[NSData dataWithBytes:b.contents
                                                length:b.length]];
        }
    }
    return bytes;
}
static id<MTLTexture> gct_texture(id<MTLDevice> device, MTLPixelFormat format)
{
    MTLTextureDescriptor *d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:32
                                                          height:32
                                                       mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> t = [device newTextureWithDescriptor:d];
    require(t != nil, nil);
    return t;
}
static id<MTLBuffer> gct_frame(NV2AMetalCommands *q,
                               NSArray<NV2AMetalGeometryResult *> *results,
                               unsigned kind)
{
    NSError *error = nil;
    NV2AMetalPixelShader *pixel =
        [[NV2AMetalPixelShader alloc] initWithDevice:q.device
                                         colorFormat:MTLPixelFormatRGBA8Unorm
                                         depthFormat:MTLPixelFormatDepth32Float
                                         sampleCount:1
                                               error:&error];
    NV2AMetalDrawConfig c = { 0 };
    c.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                   NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                   NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                   NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                   NV_PGRAPH_CONTROL_0_ZENABLE |
                   NV_PGRAPH_CONTROL_0_ZWRITEENABLE | 7u << 16;
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:q.device
                                            config:&c
                                             error:&error];
    require(pixel && state, error);
    NV2AMetalPixelUniforms u = { .clip_range = { 0, 16777215, 0, 16777215 },
                                 .clip_regions = { { 0, 0, 32, 32 } },
                                 .surface_scale = { 1, 1 },
                                 .depth_format = NV2AMetalPixelDepthD24,
                                 .two_side = 1,
                                 .z_perspective = 1,
                                 .depth_offset = .125f,
                                 .depth_factor = 1.5f };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    id<MTLTexture> color = gct_texture(q.device, MTLPixelFormatRGBA8Unorm),
                   depth = gct_texture(q.device, MTLPixelFormatDepth32Float);
    uint64_t seven = 7;
    id<MTLBuffer> query =
        [q.device newBufferWithBytes:&seven
                              length:8
                             options:MTLResourceStorageModeShared];
    id<MTLBuffer> out =
        [q.device newBufferWithLength:16392
                              options:MTLResourceStorageModeShared];
    require(query && out && [q addResource:query error:&error] &&
                [q addResource:out error:&error],
            error);
    memset(out.contents, 0xcd, out.length);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(.91, .92, .93, .94);
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.depthAttachment.clearDepth = 1;
    pass.visibilityResultBuffer = query;
    pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    NV2AMetalPixelTexture textures[4] = { 0 };
    NSMutableArray<NV2AMetalPixelDraw *> *packets = [NSMutableArray new];
    for (NV2AMetalGeometryResult *g in results) {
        unsigned options = g.directPolygonOptions  ?:
                               g.directQuadOptions ?:
                                                     g.directTriangleOptions;
        NV2AMetalPixelRasterClass raster =
            g.compactPolygons ? NV2AMetalPixelRasterCompactPolygon :
            g.compactLines    ? NV2AMetalPixelRasterCompactLine :
            g.directPolygonOptions || g.directQuadOptions || g.directTriangles ?
                             NV2AMetalPixelRasterDirectTriangle | options :
            g.directPoints     ? NV2AMetalPixelRasterDirectPoint :
            g.expandedLines    ? NV2AMetalPixelRasterExpandedLine :
            g.expandedPolygons ? NV2AMetalPixelRasterExpandedPolygon :
                                 NV2AMetalPixelRasterNative;
        NV2AMetalPixelDraw *p = [pixel prepareGeometry:g
                                                offset:0
                                                 count:g.vertexCount
                                              uniforms:&u
                                              textures:textures
                                                  pass:pass
                                             drawState:state
                                           rasterClass:raster
                                  ignorePolygonCulling:YES
                                              commands:q
                                                 error:&error];
        require(p != nil, error);
        [packets addObject:p];
    }
    id<MTL4RenderCommandEncoder> e =
        [q.commandBuffer renderCommandEncoderWithDescriptor:pass];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    BOOL mixed =
        results.count > 1 && gct_primitive(kind) != NV2AMetalPrimitivePolygon;
    NSUInteger rounds = mixed ? results[0].primitiveCount : 1;
    for (NSUInteger p = 0; p < rounds; p++)
        for (NSUInteger mode = 0; mode < results.count; mode++) {
            NV2AMetalGeometryResult *g = results[mode];
            NV2AMetalPixelDraw *packet = packets[mode];
            require(
                mixed ?
                    [packet encodeWithRenderEncoder:e
                                           commands:q
                                        firstVertex:p * g.verticesPerPrimitive
                                        vertexCount:g.verticesPerPrimitive
                                              error:&error] :
                    [packet encodeWithRenderEncoder:e commands:q error:&error],
                error);
        }
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    id<MTL4ComputeCommandEncoder> copy =
        [q.commandBuffer computeCommandEncoder];
    require(copy != nil, nil);
    [copy barrierAfterQueueStages:MTLStageAll
                     beforeStages:MTLStageBlit
                visibilityOptions:MTL4VisibilityOptionDevice];
    for (unsigned i = 0; i < 2; i++)
        [copy copyFromTexture:i ? depth : color
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(32, 32, 1)
                            toBuffer:out
                   destinationOffset:i * 8192
              destinationBytesPerRow:256
            destinationBytesPerImage:0];
    [copy copyFromBuffer:query
             sourceOffset:0
                 toBuffer:out
        destinationOffset:16384
                     size:8];
    [copy endEncoding];
    return out;
}
static NSData *gct_frame_bytes(id<MTLBuffer> out)
{
    NSMutableData *bytes = [NSMutableData new];
    const uint8_t *p = out.contents;
    for (unsigned layer = 0; layer < 2; layer++)
        for (unsigned y = 0; y < 32; y++) {
            const uint8_t *row = p + layer * 8192 + y * 256;
            [bytes appendBytes:row length:128];
            for (unsigned i = 128; i < 256; i++)
                assert(row[i] == 0xcd);
        }
    uint64_t query;
    memcpy(&query, p + 16384, 8);
    assert(query > 7);
    [bytes appendBytes:&query length:8];
    return bytes;
}
static void gct_pair(unsigned kind, BOOL gated)
{
    NSArray *reference = nil;
    GeometryContinuationNativeWork works[2] = { 0 };
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            fixture();
            NSError *error = nil;
            NV2AMetalSurfaceCache *cache = surfaces.cache;
            NV2AMetalCommands *q = cache.commands;
            require([cache beginRecordingWithError:&error], error);
            NV2AMetalGeometry *engine =
                [[NV2AMetalGeometry alloc] initWithDevice:q.device
                                                    error:&error];
            require(engine != nil, error);
            GCTInput *input = gct_input(q, kind);
            NV2AMetalGeometryContinuation *ticket = nil;
            GeometryContinuationNativeWork original = { .reference =
                                                            !candidate };
            NSArray<NV2AMetalGeometryResult *> *old = gct_encode(
                engine, input, kind, cache, &original, &ticket, &error);
            require(old != nil, error);
            NV2AMetalSurfaceRecording *token = cache.recording;
            id<MTLSharedEvent> gate = nil;
            if (gated) {
                gate = [q.device newSharedEvent];
                Ivar iv = class_getInstanceVariable(NV2AMetalCommands.class,
                                                    "_queue");
                id<MTL4CommandQueue> queue = object_getIvar(q, iv);
                require(gate && queue, nil);
                [queue waitForEvent:gate value:1];
            }
            require([cache submitWithError:&error], error);
            NV2AMetalSubmission *first = q.lastSubmitted;
            if (!gated)
                require([cache waitUntilIdleWithError:&error], error);
            require([cache beginRecordingWithError:&error], error);
            NSArray<NV2AMetalGeometryResult *> *fresh =
                gct_continue(engine, ticket, cache, &works[candidate]);
            BOOL used = fresh != nil;
            if (!fresh) {
                NV2AMetalGeometryRasterConfig c = gct_config(kind);
                gct_work = &works[candidate];
                @try {
                    fresh = [engine encodeNativeRasterSlice:input.slice
                                                  primitive:gct_primitive(kind)
                                                     config:&c
                                                     smooth:NO
                                             firstProvoking:YES
                                               zPerspective:YES
                                                   commands:q
                                                      error:&error];
                } @finally {
                    gct_work = NULL;
                }
            }
            require(fresh != nil, error);
            BOOL oldRejected = YES, newReady = YES;
            for (NSUInteger i = 0; i < old.count; i++) {
                if (old[i].compactLines) {
                    oldRejected &= ![old[i] canUseLineCoverageForCommands:q];
                    newReady &= [fresh[i] canUseLineCoverageForCommands:q];
                }
                if (old[i].compactPolygons) {
                    oldRejected &= ![old[i] canUsePolygonCoverageForCommands:q];
                    newReady &= [fresh[i] canUsePolygonCoverageForCommands:q];
                }
            }
            BOOL once =
                !candidate || ![engine continueNativeRasterGeometry:ticket
                                                       surfaceCache:cache
                                                           commands:q];
            NSArray *oldReads = gct_collect(q, old),
                    *newReads = gct_collect(q, fresh);
            id<MTLBuffer> frame = gct_frame(q, fresh, kind);
            require([cache submitWithError:&error], error);
            if (gated) {
                NSError *pending = nil;
                BOOL done = [first completedWithError:&pending];
                assert(!done && !pending && gate.signaledValue == 0);
                const uint8_t *p = frame.contents;
                for (NSUInteger i = 0; i < frame.length; i++)
                    assert(p[i] == 0xcd);
                gate.signaledValue = 1;
            }
            require([cache waitUntilIdleWithError:&error], error);
            NSArray *raw = gct_result_bytes(fresh, newReads);
            assert([raw isEqualToArray:gct_result_bytes(old, oldReads)]);
            NSArray *actual = @[ gct_frame_bytes(frame), raw ];
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            assert(token.submitted && !token.cancelled && used == !!candidate &&
                   oldRejected && newReady && once);
            for (NSUInteger i = 0; i < old.count; i++) {
                if (candidate) {
                    assert(fresh[i] != old[i] &&
                           fresh[i].vertices == old[i].vertices &&
                           fresh[i].lineCoverage == old[i].lineCoverage &&
                           fresh[i].polygonCoverage == old[i].polygonCoverage &&
                           fresh[i].polygonProjections ==
                               old[i].polygonProjections &&
                           fresh[i].polygonFacing == old[i].polygonFacing);
                }
            }
        }
    }
    assert(works[0].dispatches > 0 && !works[1].dispatches &&
           !works[1].buffers && !works[1].uploads && !works[1].encoders &&
           !works[1].waits);
    groups++;
}
static NV2AMetalVertexSlice *gct_subslice(NV2AMetalCommands *q, GCTInput *input,
                                          NSUInteger count)
{
    NSError *error = nil;
    NV2AMetalVertexStream *stream =
        [[NV2AMetalVertexStream alloc] initWithDevice:q.device
                                                limit:16
                                                error:&error];
    require(stream && [stream appendVertices:input.buffer
                                       first:2
                                       count:count
                                       error:&error],
            error);
    NV2AMetalVertexSlice *slice =
        [stream encodeSliceForDrawingWithCommands:q error:&error];
    require(slice != nil, error);
    return slice;
}
static void gct_empty_direct(void)
{
    NSArray *reference = nil;
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            fixture();
            NSError *error = nil;
            NV2AMetalSurfaceCache *cache = surfaces.cache;
            NV2AMetalCommands *q = cache.commands;
            NV2AMetalGeometry *engine =
                [[NV2AMetalGeometry alloc] initWithDevice:q.device
                                                    error:&error];
            require(engine != nil, error);
            require([cache beginRecordingWithError:&error], error);
            GCTInput *input = gct_input(q, 0);
            NSMutableArray *results = [NSMutableArray new];
            GeometryContinuationNativeWork work = { .reference = !candidate };
            for (unsigned n = 0; n < 4; n++) {
                NV2AMetalVertexSlice *slice =
                    gct_subslice(q, input, n == 2 ? 1 : 2);
                NV2AMetalGeometryRasterConfig c = gct_config(3);
                c.lineWidth = 1;
                c.lineSmooth = NO;
                enum NV2AMetalPrimitive primitive =
                    n == 0 ? NV2AMetalPrimitiveTriangles :
                    n == 1 ? NV2AMetalPrimitivePolygon :
                    n == 2 ? NV2AMetalPrimitivePoints :
                             NV2AMetalPrimitiveLines;
                NV2AMetalGeometryContinuation *ticket = nil;
                gct_work = &work;
                NSArray *one;
                @try {
                    one = [engine encodeNativeRasterSlice:slice
                                                primitive:primitive
                                                   config:&c
                                                   smooth:YES
                                           firstProvoking:NO
                                             zPerspective:NO
                                                 commands:q
                                             surfaceCache:cache
                                             continuation:&ticket
                                                    error:&error];
                } @finally {
                    gct_work = NULL;
                }
                require(one != nil, error);
                assert(!ticket);
                if (n < 2)
                    for (NV2AMetalGeometryResult *g in one)
                        assert(!g.vertexCount && !g.lineCoverage &&
                               !g.polygonCoverage && !g.polygonFacing);
                [results addObjectsFromArray:one];
            }
            NSArray *reads = gct_collect(q, results);
            require([cache submitWithError:&error] &&
                        [cache waitUntilIdleWithError:&error],
                    error);
            NSArray *actual = gct_result_bytes(results, reads);
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            assert(!work.dispatches && !work.buffers && !work.uploads &&
                   !work.encoders && ![engine valueForKey:@"module"]);
        }
    }
    groups++;
}
static void gct_lease(void)
{
    fixture();
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NV2AMetalCommands *q = cache.commands;
    NV2AMetalGeometry *engine =
        [[NV2AMetalGeometry alloc] initWithDevice:q.device error:&error];
    require(engine != nil, error);
    NV2AMetalGeometryContinuation *ticket = nil;
    NSArray *baseline = nil;
    __weak id<MTLBuffer> weakSource;
    __weak NV2AMetalIndexedVertices *weakOwner;
    @autoreleasepool {
        require([cache beginRecordingWithError:&error], error);
        GCTInput *input = gct_input(q, 1);
        weakSource = input.buffer;
        weakOwner = input.owner;
        GeometryContinuationNativeWork work = { 0 };
        NSArray *original =
            gct_encode(engine, input, 1, cache, &work, &ticket, &error);
        require(original && ticket, error);
        NSArray *reads = gct_collect(q, original);
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        baseline = gct_result_bytes(original, reads);
    }
    assert(weakSource && weakOwner);
    @autoreleasepool {
        require([cache beginRecordingWithError:&error], error);
        GeometryContinuationNativeWork work = { 0 };
        NSArray<NV2AMetalGeometryResult *> *continued =
            gct_continue(engine, ticket, cache, &work);
        require(continued != nil, nil);
        BOOL ready = [continued[0] canUseLineCoverageForCommands:q];
        BOOL once = ![engine continueNativeRasterGeometry:ticket
                                             surfaceCache:cache
                                                 commands:q];
        NSArray *reads = gct_collect(q, continued);
        id<MTLBuffer> frame = gct_frame(q, continued, 1);
        require([cache submitWithError:&error] &&
                    [cache waitUntilIdleWithError:&error],
                error);
        assert([baseline isEqualToArray:gct_result_bytes(continued, reads)]);
        gct_frame_bytes(frame);
        assert(ready && once && !work.buffers && !work.uploads &&
               !work.encoders && !work.dispatches && !work.waits);
        ticket = nil;
    }
    assert(!weakSource && !weakOwner);
    groups++;
}
static void gct_guards(void)
{
    fixture();
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NV2AMetalCommands *q = cache.commands;
    NV2AMetalGeometry *engine =
        [[NV2AMetalGeometry alloc] initWithDevice:q.device error:&error];
    require(engine != nil, error);
    require([cache beginRecordingWithError:&error], error);
    GCTInput *input = gct_input(q, 4);
    GeometryContinuationNativeWork work = { 0 };
    NV2AMetalGeometryContinuation *ticket = nil;
    NSArray<NV2AMetalGeometryResult *> *old =
        gct_encode(engine, input, 4, cache, &work, &ticket, &error);
    require(old && ticket, error);
    assert(!gct_continue(engine, ticket, cache, &work));
    require([cache checkpointWithError:&error] &&
                [cache beginRecordingWithError:&error],
            error);
    assert(!gct_continue(engine, ticket, cache,
                         &work)); /* Sealing is not submission. */
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    NV2AMetalCommands *otherCommands =
        [[NV2AMetalCommands alloc] initWithDevice:q.device error:&error];
    id<MTLBuffer> otherVRAM =
        [q.device newBufferWithLength:4096
                              options:MTLResourceStorageModeShared];
    NV2AMetalSurfaceCache *other =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:otherCommands
                                                   vram:otherVRAM
                                           didWriteVRAM:nil
                                                  error:&error];
    require(other && [other beginRecordingWithError:&error], error);
    assert(![engine continueNativeRasterGeometry:ticket
                                    surfaceCache:other
                                        commands:otherCommands]);
    for (NV2AMetalGeometryResult *g in old) {
        if (g.compactLines)
            assert(![g canUseLineCoverageForCommands:otherCommands]);
        if (g.compactPolygons)
            assert(![g canUsePolygonCoverageForCommands:otherCommands]);
    }
    [other cancel];
    require([cache beginRecordingWithError:&error], error);
    /* Publicly returned Mixed containers can be mutable; changed ordering
     * is not the exact whole-group capability. Restore and retry it. */
    assert([old isKindOfClass:NSMutableArray.class] && old.count == 2);
    [(NSMutableArray *)old exchangeObjectAtIndex:0 withObjectAtIndex:1];
    assert(!gct_continue(engine, ticket, cache, &work));
    [(NSMutableArray *)old exchangeObjectAtIndex:0 withObjectAtIndex:1];
    NSArray *continued = gct_continue(engine, ticket, cache, &work);
    require(continued != nil, nil);
    NSArray *oldReads = gct_collect(q, old),
            *newReads = gct_collect(q, continued);
    id<MTLBuffer> frame = gct_frame(q, continued, 4);
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    assert([gct_result_bytes(old, oldReads)
        isEqualToArray:gct_result_bytes(continued, newReads)]);
    gct_frame_bytes(frame);
    /* A cancelled origin cannot be revived by an unrelated older successful
     * lastSubmitted receipt or by opening a larger recording serial. */
    require([cache beginRecordingWithError:&error], error);
    ticket = nil;
    old = gct_encode(engine, input, 0, cache, &work, &ticket, &error);
    require(old && ticket, error);
    NV2AMetalSurfaceRecording *cancelled = cache.recording;
    [cache cancel];
    require([cache beginRecordingWithError:&error], error);
    assert(cancelled.cancelled && !gct_continue(engine, ticket, cache, &work));
    NV2AMetalGeometryRasterConfig c = gct_config(0);
    continued = [engine encodeNativeRasterSlice:input.slice
                                      primitive:gct_primitive(0)
                                         config:&c
                                         smooth:NO
                                 firstProvoking:YES
                                   zPerspective:YES
                                       commands:q
                                          error:&error];
    require(continued != nil, error);
    NSArray *reads = gct_collect(q, continued);
    frame = gct_frame(q, continued, 0);
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    assert(gct_result_bytes(continued, reads).count);
    gct_frame_bytes(frame);
    /* Existing ordered preflight failures remain before every native work. */
    require([cache beginRecordingWithError:&error], error);
    for (unsigned n = 0; n < 3; n++) {
        c = gct_config(3);
        if (!n)
            c.lineWidth = NAN;
        else if (n == 1)
            c.viewportWidth = 0;
        else
            c.front = (enum NV2AMetalPolygonMode)99;
        GeometryContinuationNativeWork bad = { 0 };
        gct_work = &bad;
        NSArray *failed;
        @try {
            failed = [engine encodeNativeRasterSlice:input.slice
                                           primitive:gct_primitive(3)
                                              config:&c
                                              smooth:NO
                                      firstProvoking:YES
                                        zPerspective:YES
                                            commands:q
                                               error:&error];
        } @finally {
            gct_work = NULL;
        }
        assert(!failed && error && !bad.encoders && !bad.dispatches &&
               !bad.buffers && !bad.uploads);
        error = nil;
    }
    [cache cancel];
    groups++;
}
static void gct_optional_failure(BOOL clone)
{
    fixture();
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NV2AMetalCommands *q = cache.commands;
    NV2AMetalGeometry *engine =
        [[NV2AMetalGeometry alloc] initWithDevice:q.device error:&error];
    require(engine != nil, error);
    require([cache beginRecordingWithError:&error], error);
    GCTInput *input = gct_input(q, 3);
    GeometryContinuationNativeWork work = { 0 };
    NV2AMetalGeometryContinuation *ticket = nil;
    gct_fail_clone = clone;
    gct_fail_ticket = !clone;
    NSArray *old = gct_encode(engine, input, 3, cache, &work, &ticket, &error);
    require(old != nil, error);
    assert(!ticket && !error && !gct_fail_clone && !gct_fail_ticket);
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error] &&
                [cache beginRecordingWithError:&error],
            error);
    NV2AMetalGeometryRasterConfig c = gct_config(3);
    NSArray *retry = [engine encodeNativeRasterSlice:input.slice
                                           primitive:gct_primitive(3)
                                              config:&c
                                              smooth:NO
                                      firstProvoking:YES
                                        zPerspective:YES
                                            commands:q
                                               error:&error];
    require(retry != nil, error);
    NSArray *oldReads = gct_collect(q, old), *newReads = gct_collect(q, retry);
    id<MTLBuffer> frame = gct_frame(q, retry, 3);
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    assert([gct_result_bytes(old, oldReads)
        isEqualToArray:gct_result_bytes(retry, newReads)]);
    gct_frame_bytes(frame);
}
static void gct_failures(void)
{
    for (unsigned stage = 0; stage < 4; stage++) {
        NSArray *reference = nil;
        for (unsigned candidate = 0; candidate < 2; candidate++) {
            @autoreleasepool {
                fixture();
                NSError *error = nil;
                NV2AMetalSurfaceCache *cache = surfaces.cache;
                NV2AMetalCommands *q = cache.commands;
                NV2AMetalGeometry *engine =
                    [[NV2AMetalGeometry alloc] initWithDevice:q.device
                                                        error:&error];
                require(engine != nil, error);
                require([cache beginRecordingWithError:&error], error);
                GCTInput *input = gct_input(q, 3);
                uint32_t initial = 0xcdcdcdcd;
                id<MTLBuffer> marker =
                    [q.device newBufferWithBytes:&initial
                                          length:4
                                         options:MTLResourceStorageModeShared];
                require(marker && [q addResource:marker error:&error], error);
                id<MTL4ComputeCommandEncoder> e =
                    [q.commandBuffer computeCommandEncoder];
                require(e != nil, nil);
                [e fillBuffer:marker range:NSMakeRange(0, 4) value:0x5a];
                [e endEncoding];
                require([cache checkpointWithError:&error] &&
                            [cache beginRecordingWithError:&error],
                        error);
                id<MTL4CommandBuffer> buffer = q.commandBuffer;
                NV2AMetalSubmission *before = q.lastSubmitted;
                uint64_t serial = q.recordingSerial;
                NSUInteger sealed = q.sealedBufferCount;
                gct_fail_function = stage == 0;
                gct_fail_buffer = stage == 1;
                gct_fail_upload = stage == 2;
                gct_fail_encoder = stage == 3;
                GeometryContinuationNativeWork work = { .reference =
                                                            !candidate };
                NV2AMetalGeometryContinuation *ticket = nil;
                NSArray *failed =
                    gct_encode(engine, input, 3, cache, &work, &ticket, &error);
                assert(!failed && !ticket && error && !gct_fail_function &&
                       !gct_fail_buffer && !gct_fail_upload &&
                       !gct_fail_encoder);
                NSArray *failure = @[
                    error.domain, @(error.code), error.localizedDescription
                ];
                BOOL preserved =
                    q.commandBuffer == buffer && q.recordingSerial == serial &&
                    q.sealedBufferCount == sealed && q.lastSubmitted == before;
                [cache cancel];
                error = nil;
                require([cache beginRecordingWithError:&error], error);
                NSArray *retry =
                    gct_encode(engine, input, 3, cache, &work, &ticket, &error);
                require(retry != nil, error);
                NSArray *reads = gct_collect(q, retry);
                id<MTLBuffer> frame = gct_frame(q, retry, 3);
                require([cache submitWithError:&error] &&
                            [cache waitUntilIdleWithError:&error],
                        error);
                NSArray *actual = @[
                    failure, gct_result_bytes(retry, reads),
                    gct_frame_bytes(frame)
                ];
                if (!candidate)
                    reference = actual;
                else
                    assert([reference isEqualToArray:actual]);
                assert(*(const uint32_t *)marker.contents ==
                           UINT32_C(0x5a5a5a5a) &&
                       preserved);
            }
        }
    }
    gct_optional_failure(NO);
    gct_optional_failure(YES);
    groups++;
}
static void geometry_continuation_tests(void)
{
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache = surfaces.cache;
    NV2AMetalCommands *q = cache.commands;
    require([cache beginRecordingWithError:&error], error);
    id<MTL4ComputeCommandEncoder> probe =
        [q.commandBuffer computeCommandEncoder];
    require(probe != nil, nil);
    Method encoder = class_getInstanceMethod(object_getClass(q.commandBuffer),
                                             @selector(computeCommandEncoder));
    Method dispatch = class_getInstanceMethod(
        object_getClass(probe),
        @selector(dispatchThreads:threadsPerThreadgroup:));
    [probe endEncoding];
    [cache cancel];
    Method admission = class_getInstanceMethod(
        NV2AMetalGeometry.class, @selector(canHandoffNativeRasterGeometry));
    Method upload = class_getInstanceMethod(
        NV2AMetalCommands.class, @selector(uploadBytes:length:offset:error:));
    Method wait = class_getInstanceMethod(NV2AMetalCommands.class,
                                          @selector(waitUntilIdleWithError:));
    Method function = class_getInstanceMethod(
        NV2AMetalShaderLibrary.class, @selector(computeFunction:error:));
    Method ticketInit = class_getInstanceMethod(
        NV2AMetalGeometryContinuation.class,
        NSSelectorFromString(@"initWithResults:surfaceCache:commands:"));
    Method ticketHook = class_getInstanceMethod(
        NV2AMetalGeometryContinuation.class,
        @selector(gct_initWithResults:surfaceCache:commands:));
    Method cloneInit = class_getInstanceMethod(
        NV2AMetalGeometryResult.class,
        NSSelectorFromString(@"initWithContinuationResult:"));
    Method cloneHook =
        class_getInstanceMethod(NV2AMetalGeometryResult.class,
                                @selector(gct_initWithContinuationResult:));
    Class deviceClass = object_getClass(q.device);
    Method buffer = class_getInstanceMethod(
        deviceClass, @selector(newBufferWithLength:options:));
    Method replacement = class_getInstanceMethod(
        NSObject.class, @selector(gct_newBufferWithLength:options:));
    class_addMethod(deviceClass, @selector(newBufferWithLength:options:),
                    method_getImplementation(buffer),
                    method_getTypeEncoding(buffer));
    class_addMethod(deviceClass, @selector(gct_newBufferWithLength:options:),
                    method_getImplementation(replacement),
                    method_getTypeEncoding(replacement));
    buffer = class_getInstanceMethod(deviceClass,
                                     @selector(newBufferWithLength:options:));
    replacement = class_getInstanceMethod(
        deviceClass, @selector(gct_newBufferWithLength:options:));
    assert(encoder && dispatch && admission && upload && wait && buffer &&
           replacement && function && ticketInit && ticketHook && cloneInit &&
           cloneHook);
    gct_admission_original = (void *)method_getImplementation(admission);
    gct_encoder_original = (void *)method_getImplementation(encoder);
    gct_dispatch_original = (void *)method_getImplementation(dispatch);
    gct_upload_original = (void *)method_getImplementation(upload);
    gct_wait_original = (void *)method_getImplementation(wait);
    gct_function_original = (void *)method_getImplementation(function);
    gct_failure = [NSError errorWithDomain:@"test.geometry-continuation"
                                      code:1
                                  userInfo:nil];
    method_setImplementation(admission, (IMP)gct_admission);
    method_setImplementation(encoder, (IMP)gct_encoder);
    method_setImplementation(dispatch, (IMP)gct_dispatch);
    method_setImplementation(upload, (IMP)gct_upload);
    method_setImplementation(wait, (IMP)gct_wait);
    method_exchangeImplementations(buffer, replacement);
    method_setImplementation(function, (IMP)gct_function);
    method_exchangeImplementations(ticketInit, ticketHook);
    method_exchangeImplementations(cloneInit, cloneHook);
    @try {
        for (unsigned kind = 0; kind < 5; kind++)
            gct_pair(kind, NO);
        gct_empty_direct();
        gct_lease();
        gct_pair(4, YES);
        gct_guards();
        gct_failures();
    } @finally {
        gct_work = NULL;
        gct_fail_buffer = gct_fail_upload = gct_fail_encoder =
            gct_fail_function = gct_fail_ticket = gct_fail_clone = 0;
        method_exchangeImplementations(cloneInit, cloneHook);
        method_exchangeImplementations(ticketInit, ticketHook);
        method_setImplementation(function, (IMP)gct_function_original);
        gct_failure = nil;
        method_exchangeImplementations(buffer, replacement);
        method_setImplementation(wait, (IMP)gct_wait_original);
        method_setImplementation(upload, (IMP)gct_upload_original);
        method_setImplementation(dispatch, (IMP)gct_dispatch_original);
        method_setImplementation(encoder, (IMP)gct_encoder_original);
        method_setImplementation(admission, (IMP)gct_admission_original);
    }
    puts("Geometry continuation:10 native groups, original/rebound "
         "metadata/source/remap/carrier/defined-projection/facing and "
         "RGBA/Zeta/query bytes; live stale/one-shot, pending Gate0, lease, "
         "failures/cancel/retry vs old rebuild PASS");
}
#endif
