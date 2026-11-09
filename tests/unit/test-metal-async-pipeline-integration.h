/* Real-Metal optional pipeline integration. Controlled completion/failure is
 * test injection; successful pipelines and all rendered results are native.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_ASYNC_PIPELINE_INTEGRATION_H
#define TEST_METAL_ASYNC_PIPELINE_INTEGRATION_H
#include "test-metal-async-pipeline-helpers.h"
#import "hw/xbox/nv2a/pgraph/metal/pipeline-compiler.h"
#include <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN

@interface NV2AMetalPipelineCompiler (AITPrivateConstructor)
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                               compiler:(id<MTL4Compiler>)compiler;
@end

/* Exact private selector ABI; no alternative key or shader algorithm. */
typedef struct NV2AMetalFragmentPipelineKey {
    uint64_t raster[4];
    unsigned control, program, finalInputs[2], words[4][8];
} NV2AMetalFragmentPipelineKey;
typedef NS_ENUM(unsigned, NV2AMetalPixelPostprocess) {
    NV2AMetalPixelPostprocessNone,
    NV2AMetalPixelPostprocessSource,
    NV2AMetalPixelPostprocessDestination,
};
_Static_assert(sizeof(NV2AMetalFragmentPipelineKey) == 176, "Private key ABI");
@interface NV2AMetalPixelShader (AITPrivateFactories)
- (nullable id<MTLRenderPipelineState>)
    newPipelineForTopology:(unsigned)topology
                 drawState:(nullable NV2AMetalDrawState *)state
               postprocess:(NV2AMetalPixelPostprocess)postprocess
               fragmentKey:(const NV2AMetalFragmentPipelineKey *)key
               rasterClass:(NV2AMetalPixelRasterClass)rasterClass
                     error:(NSError *_Nullable *_Nullable)error;
- (nullable id<MTLRenderPipelineState>)
    interpreterPipelineForTopology:(unsigned)topology
                         drawState:(nullable NV2AMetalDrawState *)state
                       postprocess:(NV2AMetalPixelPostprocess)postprocess
                       fragmentKey:(const NV2AMetalFragmentPipelineKey *)key
                       rasterClass:(NV2AMetalPixelRasterClass)rasterClass;
@end

@interface AITShader : GenericRenderShader
@property(nonatomic) BOOL failGeneric;
@property(nonatomic) unsigned syncCalls, genericCalls;
@property(nonatomic, nullable) id<MTLRenderPipelineState> lastGeneric,
    lastPipeline;
@end
@implementation AITShader
- (nullable id<MTLRenderPipelineState>)
    newPipelineForTopology:(unsigned)t
                 drawState:(nullable NV2AMetalDrawState *)s
               postprocess:(NV2AMetalPixelPostprocess)p
               fragmentKey:(const NV2AMetalFragmentPipelineKey *)k
               rasterClass:(NV2AMetalPixelRasterClass)r
                     error:(NSError *_Nullable *_Nullable)e
{
    _syncCalls++;
    return [super newPipelineForTopology:t
                               drawState:s
                             postprocess:p
                             fragmentKey:k
                             rasterClass:r
                                   error:e];
}
- (nullable id<MTLRenderPipelineState>)
    interpreterPipelineForTopology:(unsigned)t
                         drawState:(nullable NV2AMetalDrawState *)s
                       postprocess:(NV2AMetalPixelPostprocess)p
                       fragmentKey:(const NV2AMetalFragmentPipelineKey *)k
                       rasterClass:(NV2AMetalPixelRasterClass)r
{
    _genericCalls++;
    if (_failGeneric)
        return nil;
    id<MTLRenderPipelineState> result =
        [super interpreterPipelineForTopology:t
                                    drawState:s
                                  postprocess:p
                                  fragmentKey:k
                                  rasterClass:r];
    _lastGeneric = result;
    return result;
}
- (nullable NV2AMetalPixelDraw *)
         prepareVertices:(nullable id<MTLBuffer>)vertices
                  offset:(NSUInteger)offset
                   count:(NSUInteger)count
               primitive:(MTLPrimitiveType)primitive
                uniforms:(const NV2AMetalPixelUniforms *)u
                textures:(const NV2AMetalPixelTexture *)textures
                    pass:(MTL4RenderPassDescriptor *)pass
            depthStencil:(nullable id<MTLDepthStencilState>)depthStencil
               drawState:(nullable NV2AMetalDrawState *)state
             rasterClass:(NV2AMetalPixelRasterClass)raster
      polygonProjections:(nullable id<MTLBuffer>)projection
           polygonFacing:(nullable id<MTLBuffer>)facing
          rasterCoverage:(nullable id<MTLBuffer>)coverage
    sourceVertexCapacity:(NSUInteger)capacity
         indexedVertices:(nullable NV2AMetalIndexedVertices *)indexed
             indexOffset:(NSUInteger)indexOffset
    ignorePolygonCulling:(BOOL)ignore
                commands:(NV2AMetalCommands *)q
                   error:(NSError *_Nullable *_Nullable)error
{
    NV2AMetalPixelDraw *draw = [super prepareVertices:vertices
                                               offset:offset
                                                count:count
                                            primitive:primitive
                                             uniforms:u
                                             textures:textures
                                                 pass:pass
                                         depthStencil:depthStencil
                                            drawState:state
                                          rasterClass:raster
                                   polygonProjections:projection
                                        polygonFacing:facing
                                       rasterCoverage:coverage
                                 sourceVertexCapacity:capacity
                                      indexedVertices:indexed
                                          indexOffset:indexOffset
                                 ignorePolygonCulling:ignore
                                             commands:q
                                                error:error];
    _lastPipeline = [draw valueForKey:@"pipeline"];
    return draw;
}
@end

@interface AITController : NV2AMetalPipelineCompiler
@property(nonatomic) unsigned readyCalls, requestCalls, builders;
@end
@implementation AITController
- (nullable id<MTLRenderPipelineState>)readyPipelineForKey:(NSData *)key
{
    _readyCalls++;
    return [super readyPipelineForKey:key];
}
- (BOOL)requestPipelineForKey:(NSData *)key
                      library:(id<MTLLibrary>)library
            descriptorBuilder:(NV2AMetalPipelineDescriptorBuilder)builder
{
    _requestCalls++;
    return [super requestPipelineForKey:key
                                library:library
                      descriptorBuilder:^{
                        self.builders++;
                        return builder();
                      }];
}
@end

@interface AITTask : NSObject <MTL4CompilerTask>
@property(nonatomic, weak, nullable) id<MTL4Compiler> compiler;
@property(nonatomic) BOOL done;
@end
@implementation AITTask
- (MTL4CompilerTaskStatus)status
{
    return _done ? MTL4CompilerTaskStatusFinished :
                   MTL4CompilerTaskStatusScheduled;
}
- (void)waitUntilCompleted
{
    assert(!"The integration must not wait on a controlled compiler task");
    abort();
}
@end
@interface AITJob : NSObject
@property(nonatomic, nullable) MTL4RenderPipelineDescriptor *descriptor;
@property(nonatomic, copy, nullable)
    MTLNewRenderPipelineStateCompletionHandler handler;
@property(nonatomic) AITTask *task;
@property(nonatomic, nullable) id<MTLRenderPipelineState> result;
@end
@implementation AITJob
@end
@interface AITControlledCompiler : NSObject
@property(nonatomic) id<MTLDevice> device;
@property(nonatomic) NSMutableArray<AITJob *> *jobs;
- (id<MTL4CompilerTask>)
    newRenderPipelineStateWithDescriptor:(MTL4PipelineDescriptor *)d
                     compilerTaskOptions:
                         (nullable MTL4CompilerTaskOptions *)options
                       completionHandler:
                           (MTLNewRenderPipelineStateCompletionHandler)handler;
- (void)complete:(NSUInteger)index using:(id<MTL4Compiler>)compiler;
- (void)failOptional:(NSUInteger)index;
@end
@implementation AITControlledCompiler
- (id<MTL4CompilerTask>)
    newRenderPipelineStateWithDescriptor:(MTL4PipelineDescriptor *)d
                     compilerTaskOptions:
                         (nullable MTL4CompilerTaskOptions *)options
                       completionHandler:
                           (MTLNewRenderPipelineStateCompletionHandler)handler
{
    assert(!options && handler &&
           [d isKindOfClass:MTL4RenderPipelineDescriptor.class]);
    AITJob *job = [AITJob new];
    job.descriptor = (MTL4RenderPipelineDescriptor *)d;
    assert(job.descriptor.vertexFunctionDescriptor &&
           job.descriptor.fragmentFunctionDescriptor);
    job.handler = handler;
    job.task = [AITTask new];
    job.task.compiler = (id<MTL4Compiler>)self;
    [_jobs addObject:job];
    return job.task;
}
- (void)complete:(NSUInteger)index using:(id<MTL4Compiler>)compiler
{
    AITJob *job = _jobs[index];
    assert(!job.task.done && job.handler && compiler.device == _device);
    NSError *error = nil;
    /* Actual captured descriptor and actual Metal compiler, not fake IR. */
    job.result = [compiler newRenderPipelineStateWithDescriptor:job.descriptor
                                            compilerTaskOptions:nil
                                                          error:&error];
    require(job.result != nil && error == nil, error);
    job.task.done = YES;
    job.handler(job.result, nil);
    job.handler = nil;
    job.descriptor = nil;
}
- (void)failOptional:(NSUInteger)index
{
    AITJob *job = _jobs[index];
    assert(!job.task.done && job.handler);
    NSError *injected =
        [NSError errorWithDomain:@"xemu.test.optional-specialization"
                            code:1
                        userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Test-injected optional compilation failure "
                                @"(not a GPU error)"
                        }];
    job.task.done = YES;
    job.handler(nil, injected);
    job.handler = nil;
    job.descriptor = nil;
}
@end

/* This second path forwards to the real asynchronous Metal API. Its explicit
 * event is signalled only after the controller's actual completion handler. */
@interface AITNativeCompiler : NSObject {
@public
    dispatch_semaphore_t completed;
    unsigned requests, callbacks;
    id<MTLRenderPipelineState> _Nullable result;
    NSError *_Nullable failure;
}
@property(nonatomic) id<MTL4Compiler> real;
@property(nonatomic, readonly) id<MTLDevice> device;
- (id<MTL4CompilerTask>)
    newRenderPipelineStateWithDescriptor:(MTL4PipelineDescriptor *)d
                     compilerTaskOptions:
                         (nullable MTL4CompilerTaskOptions *)options
                       completionHandler:
                           (MTLNewRenderPipelineStateCompletionHandler)handler;
@end
@implementation AITNativeCompiler
- (id<MTLDevice>)device
{
    return _real.device;
}
- (id<MTL4CompilerTask>)
    newRenderPipelineStateWithDescriptor:(MTL4PipelineDescriptor *)d
                     compilerTaskOptions:
                         (nullable MTL4CompilerTaskOptions *)options
                       completionHandler:
                           (MTLNewRenderPipelineStateCompletionHandler)handler
{
    requests++;
    return [_real
        newRenderPipelineStateWithDescriptor:d
                         compilerTaskOptions:options
                           completionHandler:^(
                               id<MTLRenderPipelineState> _Nullable pipeline,
                               NSError *_Nullable error) {
                             handler(pipeline, error);
                             @synchronized(self) {
                                 callbacks++;
                                 result = pipeline;
                                 failure = error;
                             }
                             dispatch_semaphore_signal(completed);
                           }];
}
@end

static BOOL (*ait_keep_original)(id, SEL, id, NSError *_Nullable *_Nullable);
static _Thread_local __unsafe_unretained id _Nullable ait_keep_wanted;
static _Thread_local unsigned ait_kept;
static BOOL ait_keep(id owner, SEL selector, id object,
                     NSError *_Nullable *_Nullable error)
{
    BOOL ok = ait_keep_original(owner, selector, object, error);
    if (ok && owner == commands && object == ait_keep_wanted)
        ait_kept++;
    return ok;
}
static AITShader *ait_shader(unsigned entry,
                             NV2AMetalPipelineCompiler *_Nullable controller)
{
    NSError *error = nil;
    AITShader *p =
        [[AITShader alloc] initWithDevice:commands.device
                              colorFormat:entry ? MTLPixelFormatRGBA8Unorm :
                                                  MTLPixelFormatRGBA32Float
                              depthFormat:MTLPixelFormatDepth32Float_Stencil8
                              sampleCount:1
                          surfaceChannels:0
                            pipelineCache:nil
                         pipelineCompiler:controller
                                    error:&error];
    require(p != nil && !error, error);
    return p;
}
static AITController *
ait_controlled(AITControlledCompiler *_Nullable *_Nonnull out)
{
    AITControlledCompiler *fake = [AITControlledCompiler new];
    fake.device = commands.device;
    fake.jobs = [NSMutableArray new];
    AITController *c =
        [[AITController alloc] initWithDevice:commands.device
                                     compiler:(id<MTL4Compiler>)fake];
    assert(c);
    *out = fake;
    return c;
}
static void ait_equal(GenericRenderFrame a, NSData *_Nullable sa,
                      GenericRenderFrame b, NSData *_Nullable sb,
                      GenericRenderScene *scene)
{
    grp_golden(&a, scene);
    grp_golden(&b, scene);
    assert(sa.length == sizeof(SumFlagsProbeConstants) &&
           sb.length == sizeof(SumFlagsProbeConstants));
    assert(!memcmp(&a, &b, sizeof(a)) && [sa isEqual:sb]);
}

/* Same-recording packet fixture: Native Tag0 only; all shader math/goldens and
 * actual readback remain the frozen grp_* implementation. */
@interface AITFixture : NSObject
@property(nonatomic) GenericRenderScene *scene;
@property(nonatomic) NV2AMetalDrawState *state;
@property(nonatomic) id<MTLBuffer> source, query;
@property(nonatomic, nullable) id<MTLBuffer> read;
@property(nonatomic) id<MTLTexture> color, zeta;
@property(nonatomic) MTL4RenderPassDescriptor *pass;
@property(nonatomic) NSData *expected, *original;
@property(nonatomic, nullable) NSData *storage;
@property(nonatomic, nullable) NV2AMetalPixelDraw *draw;
@property(nonatomic, nullable) NV2AMetalSubmission *receipt;
@end
@implementation AITFixture
@end
static AITFixture *ait_fixture(GenericRenderScene *scene)
{
    assert(!scene.entry && !scene.geometryMode && !scene.halfDepth);
    AITFixture *f = [AITFixture new];
    f.scene = scene;
    f.state = grp_state(0);
    f.color = grp_target(MTLPixelFormatRGBA32Float);
    f.zeta = grp_target(MTLPixelFormatDepth32Float_Stencil8);
    f.source =
        [commands.device newBufferWithBytes:scene->vertices
                                     length:sizeof(scene->vertices)
                                    options:MTLResourceStorageModeShared];
    f.query =
        [commands.device newBufferWithLength:8
                                     options:MTLResourceStorageModeShared];
    assert(f.source && f.query);
    memset(f.query.contents, 0, 8);
    f.pass = [MTL4RenderPassDescriptor new];
    f.pass.colorAttachments[0].texture = f.color;
    f.pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    f.pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    f.pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 0);
    f.pass.depthAttachment.texture = f.zeta;
    f.pass.depthAttachment.loadAction = MTLLoadActionClear;
    f.pass.depthAttachment.storeAction = MTLStoreActionStore;
    f.pass.depthAttachment.clearDepth = .99;
    f.pass.stencilAttachment.texture = f.zeta;
    f.pass.stencilAttachment.loadAction = MTLLoadActionClear;
    f.pass.stencilAttachment.storeAction = MTLStoreActionStore;
    f.pass.stencilAttachment.clearStencil = 0x11;
    f.pass.visibilityResultBuffer = f.query;
    f.pass.visibilityResultType = MTLVisibilityResultTypeReset;
    SumFlagsProbeConstants expected = { .uniforms = scene->u };
    expected.uniforms.vertex_capacity = 6;
    expected.uniforms.point_sprite = 0;
    expected.uniforms.logic_op =
        f.state.logicEnabled ? f.state.logicOperation + 1 : 0;
    expected.uniforms.dither = f.state.ditherEnabled;
    expected.uniforms.blend = f.state.blendWord;
    nv2a_metal_color_bits(f.color.pixelFormat, expected.uniforms.color_bits);
    f.expected = [NSData dataWithBytes:&expected length:sizeof(expected)];
    f.original = [NSData dataWithBytes:&scene->u length:sizeof(scene->u)];
    return f;
}
static NV2AMetalPixelDraw *_Nullable ait_prepare(
    AITShader *p, AITFixture *f, id<MTLBuffer> source,
    const NV2AMetalPixelUniforms *u, const NV2AMetalPixelTexture *textures,
    NSError *_Nullable *_Nullable error)
{
    return [p prepareVertices:source
                       offset:0
                        count:6
                    primitive:MTLPrimitiveTypeTriangle
                     uniforms:u
                     textures:textures
                         pass:f.pass
                 depthStencil:f.state.depthStencil
                    drawState:f.state
                  rasterClass:NV2AMetalPixelRasterNative
           polygonProjections:nil
                polygonFacing:nil
               rasterCoverage:nil
         sourceVertexCapacity:0
              indexedVertices:nil
                  indexOffset:0
         ignorePolygonCulling:YES
                     commands:commands
                        error:error];
}
static void ait_valid_prepare(AITShader *p, AITFixture *f)
{
    NSError *error = nil;
    p.expected = f.expected;
    grp_expected = f.expected.bytes;
    @try {
        f.draw =
            ait_prepare(p, f, f.source, &f.scene->u, f.scene->textures, &error);
    } @finally {
        grp_expected = NULL;
        p.expected = nil;
    }
    require(f.draw != nil && !error, error);
    f.storage = p.storage;
    assert([f.expected isEqual:f.storage] &&
           !memcmp(f.original.bytes, &f.scene->u, sizeof(f.scene->u)));
}
static void ait_emit(AITFixture *f)
{
    NSError *error = nil;
    for (id resource in @[ f.color, f.zeta, f.query ])
        require([commands addResource:resource error:&error], error);
    id<MTL4RenderCommandEncoder> e =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:f.pass];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:nv2a_metal_pixel_pass_stages()
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    require([f.draw encodeWithRenderEncoder:e commands:commands error:&error],
            error);
    [e barrierAfterStages:nv2a_metal_pixel_pass_stages()
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
}
static GenericRenderFrame ait_frame(AITFixture *f)
{
    NSError *error = nil;
    require([f.receipt completedWithError:&error] && !error, error);
    assert(f.read.length >= sizeof(((GenericRenderFrame *)0)->pixels));
    GenericRenderFrame frame = { 0 };
    memcpy(frame.pixels, f.read.contents, sizeof(frame.pixels));
    memcpy(&frame.query, f.query.contents, sizeof(frame.query));
    assert(!memcmp(f.original.bytes, &f.scene->u, sizeof(f.scene->u)));
    return frame;
}

static void ait_guard_tests(AITShader *candidate, AITShader *reference,
                            AITController *controller)
{
    GenericRenderScene *s = grp_scene(0, 0);
    AITFixture *f = ait_fixture(s);
    id<MTLBuffer> shortInput =
        [commands.device newBufferWithLength:sizeof(s->vertices) - 1
                                     options:MTLResourceStorageModeShared];
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    unsigned requests = controller.requestCalls, ready = controller.readyCalls,
             builders = controller.builders;
    grp_compiler = [candidate valueForKey:@"compiler"];
    grp_requests = grp_uploads = 0;
    grp_guard_upload_scope = YES;
    @try {
        for (unsigned bad = 0; bad < 3; bad++) {
            NSError *errors[2] = { nil, nil };
            AITShader *owners[2] = { reference, candidate };
            for (unsigned v = 0; v < 2; v++) {
                NV2AMetalPixelUniforms u = s->u;
                NV2AMetalPixelTexture textures[4];
                memcpy(textures, s->textures, sizeof(textures));
                if (bad == 1)
                    u.combiner.control = 9;
                if (bad == 2)
                    textures[0].texture = nil;
                NSError *local = nil;
                assert(!ait_prepare(owners[v], f, bad ? f.source : shortInput,
                                    &u, textures, &local) &&
                       local);
                errors[v] = local;
            }
            assert([errors[0].domain isEqual:errors[1].domain] &&
                   errors[0].code == errors[1].code &&
                   [errors[0].localizedDescription
                       isEqual:errors[1].localizedDescription]);
        }
        assert(!grp_requests && !grp_uploads &&
               controller.requestCalls == requests &&
               controller.readyCalls == ready &&
               controller.builders == builders);
    } @finally {
        grp_guard_upload_scope = NO;
        grp_compiler = nil;
        [commands cancel];
    }
}

static void ait_packet_tests(NV2AMetalGeometry *engine,
                             id<MTL4Compiler> builder,
                             GenericRenderFrame referenceFrame,
                             NSData *referenceStorage,
                             AITShader *referenceShader)
{
    (void)engine;
    AITControlledCompiler *fake = nil;
    AITController *controller = ait_controlled(&fake);
    AITShader *p = ait_shader(0, controller);
    GenericRenderScene *s = grp_scene(0, 0);
    AITFixture *a = ait_fixture(s), *b = ait_fixture(s);
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    uint64_t serial = commands.recordingSerial;
    [p beginPreparationForPass:a.pass commands:commands];
    ait_valid_prepare(p, a);
    id generic = [a.draw valueForKey:@"pipeline"];
    assert(generic && generic == p.lastGeneric && !p.syncCalls &&
           fake.jobs.count == 1);
    [fake complete:0 using:builder];
    id specialized = fake.jobs[0].result;
    assert(specialized && specialized != generic);
    unsigned ready = controller.readyCalls;
    NV2AMetalPixelDraw *original = a.draw;
    ait_valid_prepare(p,
                      a); // Existing shared slot intentionally remains generic.
    assert([a.draw valueForKey:@"pipeline"] == generic &&
           controller.readyCalls == ready &&
           [original valueForKey:@"pipeline"] == generic);
    a.draw = original;
    [p endPreparation];
    [p beginPreparationForPass:b.pass commands:commands];
    ait_keep_wanted = specialized;
    ait_kept = 0;
    unsigned sync = p.syncCalls;
    grp_compiler = [p valueForKey:@"compiler"];
    grp_requests = 0;
    ait_valid_prepare(p, b); // Ordinary full lookup adopts and freshly retains.
    assert([b.draw valueForKey:@"pipeline"] == specialized && ait_kept == 1 &&
           !grp_requests && p.syncCalls == sync &&
           [original valueForKey:@"pipeline"] == generic &&
           commands.recordingSerial == serial);
    ait_keep_wanted = nil;
    grp_compiler = nil;
    [p endPreparation];
    /* Foreign owner at the SAME serial cannot use either prepared packet. */
    NV2AMetalCommands *other = [[NV2AMetalCommands alloc] initWithError:&error];
    require(other && other.device == commands.device, error);
    while (other.recordingSerial < serial) {
        require([other beginWithError:&error] != nil, error);
        if (other.recordingSerial < serial)
            [other cancel];
    }
    assert(other.commandBuffer && other.recordingSerial == serial);
    for (id r in @[ a.color, a.zeta, a.query ])
        require([other addResource:r error:&error], error);
    id<MTL4RenderCommandEncoder> foreign =
        [other.commandBuffer renderCommandEncoderWithDescriptor:a.pass];
    require(foreign != nil, nil);
    for (NV2AMetalPixelDraw *d in @[ original, b.draw ]) {
        error = nil;
        assert(![d encodeWithRenderEncoder:foreign
                                  commands:other
                                     error:&error] &&
               error);
    }
    [foreign endEncoding];
    [other cancel];
    assert(commands.recordingSerial == serial);
    ait_emit(a);
    ait_emit(b);
    a.read = grp_read(a.color, a.zeta);
    b.read = grp_read(b.color, b.zeta);
    require([commands submitWithError:&error], error);
    a.receipt = b.receipt = commands.lastSubmitted;
    require([commands waitUntilIdleWithError:&error], error);
    ait_equal(referenceFrame, referenceStorage, ait_frame(a), a.storage, s);
    ait_equal(referenceFrame, referenceStorage, ait_frame(b), b.storage, s);
    /* Actual recording retirement must leave both old capabilities stale. */
    require([commands beginWithError:&error] != nil, error);
    assert(commands.recordingSerial != serial);
    for (id r in @[ a.color, a.zeta, a.query ])
        require([commands addResource:r error:&error], error);
    id<MTL4RenderCommandEncoder> stale =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:a.pass];
    require(stale != nil, nil);
    for (NV2AMetalPixelDraw *d in @[ original, b.draw ]) {
        error = nil;
        assert(![d encodeWithRenderEncoder:stale
                                  commands:commands
                                     error:&error] &&
               error);
    }
    [stale endEncoding];
    [commands cancel];
    ait_guard_tests(p, referenceShader, controller);
}

static void async_pipeline_integration_body(void)
{
    assert(commands && !commands.commandBuffer);
    NSError *error = nil;
    grp_prepare_reader();
    NV2AMetalGeometry *engine =
        [[NV2AMetalGeometry alloc] initWithDevice:commands.device error:&error];
    require(engine != nil, error);
    id<MTL4Compiler> builder =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(builder != nil, error);
    AITShader *reference = ait_shader(0, nil);
    assert(![reference valueForKey:@"pipelineCompiler"]);
    id<MTL4Compiler> synchronous = [reference valueForKey:@"compiler"];
    Method native = class_getInstanceMethod(
        [synchronous class],
        @selector(
            newRenderPipelineStateWithDescriptor:compilerTaskOptions:error:));
    Method upload = class_getInstanceMethod(
        NV2AMetalCommands.class, @selector(uploadBytes:length:offset:error:));
    Method keep = class_getInstanceMethod(NV2AMetalCommands.class,
                                          @selector(keepAlive:error:));
    assert(native && upload && keep);
    grp_native_original = (void *)method_getImplementation(native);
    grp_upload_original = (void *)method_getImplementation(upload);
    ait_keep_original = (void *)method_getImplementation(keep);
    method_setImplementation(native, (IMP)grp_native);
    method_setImplementation(upload, (IMP)grp_upload);
    method_setImplementation(keep, (IMP)ait_keep);
    @try {
        /* Three real entry points compete for TWO optional permits. */
        AITControlledCompiler *fake = nil;
        AITController *controller = ait_controlled(&fake);
        GenericRenderFrame refs[3];
        NSData *refStorage[3];
        AITShader *pending[3];
        for (unsigned i = 0; i < 3; i++) {
            GenericRenderScene *s = grp_scene(i ? 6 : 0, i ? i + 1 : 0);
            AITShader *sync = i ? ait_shader(i, nil) : reference;
            pending[i] = ait_shader(i, controller);
            grp_compiler = nil;
            NSData *referenceStorage = nil;
            refs[i] = grp_render(sync, engine, s, &referenceStorage);
            refStorage[i] = referenceStorage;
            grp_compiler = [pending[i] valueForKey:@"compiler"];
            grp_requests = 0;
            NSData *storage = nil;
            GenericRenderFrame actual =
                grp_render(pending[i], engine, s, &storage);
            ait_equal(refs[i], refStorage[i], actual, storage, s);
            assert(pending[i].lastPipeline == pending[i].lastGeneric &&
                   pending[i].lastPipeline && !pending[i].syncCalls &&
                   grp_requests == 1);
        }
        assert(fake.jobs.count == 2 && controller.builders == 2 &&
               controller.requestCalls == 3);
        GenericRenderScene *third = grp_scene(6, 3);
        NSData *thirdStorage = nil;
        grp_compiler = [pending[2] valueForKey:@"compiler"];
        grp_requests = 0;
        GenericRenderFrame thirdFrame =
            grp_render(pending[2], engine, third, &thirdStorage);
        ait_equal(refs[2], refStorage[2], thirdFrame, thirdStorage, third);
        assert(!grp_requests && !pending[2].syncCalls && fake.jobs.count == 2 &&
               controller.builders == 2 &&
               pending[2].lastPipeline == pending[2].lastGeneric);
        grp_compiler = nil;
        [fake complete:0 using:builder];
        [fake failOptional:1];
        /* Test-injected OPTIONAL failure must keep the already valid generic
         * pipeline, with no synchronous specialization or retry builder. */
        unsigned failedBuilders = controller.builders;
        id failedGeneric = pending[1].lastGeneric;
        GenericRenderScene *failedScene = grp_scene(6, 2);
        NSData *failedStorage = nil;
        grp_compiler = [pending[1] valueForKey:@"compiler"];
        grp_requests = 0;
        GenericRenderFrame failedFrame =
            grp_render(pending[1], engine, failedScene, &failedStorage);
        ait_equal(refs[1], refStorage[1], failedFrame, failedStorage,
                  failedScene);
        assert(failedGeneric && pending[1].lastPipeline == failedGeneric &&
               !pending[1].syncCalls && !grp_requests &&
               controller.builders == failedBuilders && fake.jobs.count == 2);
        grp_compiler = nil;
        ait_packet_tests(engine, builder, refs[0], refStorage[0], reference);
        /* A simulated optional-generic failure uses the original sync API. */
        AITControlledCompiler *fallbackFake = nil;
        AITController *fallbackController = ait_controlled(&fallbackFake);
        AITShader *fallback = ait_shader(0, fallbackController);
        fallback.failGeneric = YES;
        GenericRenderScene *simple = grp_scene(0, 0);
        grp_compiler = [fallback valueForKey:@"compiler"];
        grp_requests = 0;
        NSData *fallbackStorage = nil;
        GenericRenderFrame fallbackFrame =
            grp_render(fallback, engine, simple, &fallbackStorage);
        ait_equal(refs[0], refStorage[0], fallbackFrame, fallbackStorage,
                  simple);
        assert(fallback.genericCalls == 1 && fallback.syncCalls == 1 &&
               grp_requests == 1 && !fallbackController.requestCalls &&
               !fallbackFake.jobs.count);
        grp_compiler = nil;
        /* Compile an actual distinct but valid specialized library. A private
         * library override must bypass every optional/generic lookup. */
        MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
        ld.source = @(metal_shader_source);
        ld.options = [MTLCompileOptions new];
        ld.options.languageVersion = MTLLanguageVersion4_0;
        ld.options.mathMode = MTLMathModeSafe;
        ld.options.mathFloatingPointFunctions =
            MTLMathFloatingPointFunctionsPrecise;
        id<MTLLibrary> foreignLibrary =
            [builder newLibraryWithDescriptor:ld error:&error];
        require(foreignLibrary != nil && !error, error);
        AITControlledCompiler *foreignFake = nil;
        AITController *foreignController = ait_controlled(&foreignFake);
        AITShader *foreignShader = ait_shader(0, foreignController);
        assert(foreignLibrary !=
               [foreignShader valueForKey:@"canonicalLibrary"]);
        [foreignShader setValue:foreignLibrary forKey:@"library"];
        grp_compiler = [foreignShader valueForKey:@"compiler"];
        grp_requests = 0;
        NSData *foreignStorage = nil;
        GenericRenderFrame foreignFrame =
            grp_render(foreignShader, engine, simple, &foreignStorage);
        ait_equal(refs[0], refStorage[0], foreignFrame, foreignStorage, simple);
        assert(!foreignShader.genericCalls && foreignShader.syncCalls == 1 &&
               grp_requests == 1 && !foreignController.readyCalls &&
               !foreignController.requestCalls && !foreignFake.jobs.count);
        grp_compiler = nil;
        /* Actual asynchronous Metal request, explicit real completion event. */
        AITNativeCompiler *actual = [AITNativeCompiler new];
        actual.real = builder;
        actual->completed = dispatch_semaphore_create(0);
        AITController *realController =
            [[AITController alloc] initWithDevice:commands.device
                                         compiler:(id<MTL4Compiler>)actual];
        assert(realController && actual->completed);
        AITShader *realShader = ait_shader(0, realController);
        NSData *nativeStorage = nil;
        GenericRenderFrame nativeFrame =
            grp_render(realShader, engine, simple, &nativeStorage);
        ait_equal(refs[0], refStorage[0], nativeFrame, nativeStorage, simple);
        assert(realShader.lastPipeline == realShader.lastGeneric &&
               !realShader.syncCalls && actual->requests == 1);
        long waited = dispatch_semaphore_wait(
            actual->completed,
            dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
        if (waited) {
            fprintf(
                stderr,
                "Actual native async compiler completion deadline expired\n");
            abort();
        }
        id<MTLRenderPipelineState> readyPipeline;
        @synchronized(actual) {
            require(actual->callbacks == 1 && actual->result &&
                        !actual->failure,
                    actual->failure);
            readyPipeline = actual->result;
        }
        ait_keep_wanted = readyPipeline;
        ait_kept = 0;
        grp_compiler = [realShader valueForKey:@"compiler"];
        grp_requests = 0;
        NSData *readyStorage = nil;
        GenericRenderFrame readyFrame =
            grp_render(realShader, engine, simple, &readyStorage);
        ait_equal(refs[0], refStorage[0], readyFrame, readyStorage, simple);
        assert(realShader.lastPipeline == readyPipeline && ait_kept == 1 &&
               !grp_requests && !realShader.syncCalls && actual->requests == 1);
        printf("Metal async integration: real frames/storage/queries equal; "
               "controlled cap2, "
               "same-recording immutable packets, guards/fallback/override and "
               "actual native completion PASS\n");
        fflush(stdout);
    } @finally {
        ait_keep_wanted = nil;
        grp_expected = NULL;
        grp_guard_upload_scope = NO;
        grp_compiler = nil;
        method_setImplementation(keep, (IMP)ait_keep_original);
        method_setImplementation(upload, (IMP)grp_upload_original);
        method_setImplementation(native, (IMP)grp_native_original);
    }
}
/* Use a fresh recorder so the same-serial foreign-owner comparison stays
 * bounded, while preserving the surrounding Pixel tests' idle recorder. */
static void async_pipeline_integration_tests(void)
{
    NV2AMetalCommands *savedCommands = commands;
    assert(savedCommands && !savedCommands.commandBuffer &&
           !savedCommands.batchSerial && !savedCommands.sealedBufferCount);
    BOOL savedManualSampling = manual_sampling;
    NSError *error = nil;
    NV2AMetalCommands *isolated =
        [[NV2AMetalCommands alloc] initWithError:&error];
    require(isolated != nil && !error &&
                isolated.device == savedCommands.device,
            error);
    assert(!isolated.commandBuffer && isolated.recordingSerial == 0);
    @try {
        commands = isolated;
        manual_sampling = YES;
        async_pipeline_integration_body();
    } @finally {
        commands = savedCommands;
        manual_sampling = savedManualSampling;
    }
}

NS_ASSUME_NONNULL_END
#endif
