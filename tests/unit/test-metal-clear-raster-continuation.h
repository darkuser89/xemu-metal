/* Native clear/raster ordering and rollback witnesses, without a window.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import <dispatch/dispatch.h>

@interface CRCCommands : NV2AMetalCommands
@property(nonatomic) unsigned submits, waits, failure;
@property(nonatomic, strong) NSError *injected;
@property(nonatomic, strong) id<MTLSharedEvent> gate;
@end
@implementation CRCCommands
- (BOOL)submitWithError:(NSError **)error
{
    self.submits++;
    return [super submitWithError:error];
}
- (BOOL)waitUntilIdleWithError:(NSError **)error
{
    self.waits++;
    if (self.gate && !self.gate.signaledValue)
        self.gate.signaledValue = 1;
    return [super waitUntilIdleWithError:error];
}
- (id<MTLBuffer>)uploadBytes:(const void *)bytes
                      length:(NSUInteger)length
                      offset:(NSUInteger *)offset
                       error:(NSError **)error
{
    if (self.failure == 1 && length == sizeof(NV2AMetalClearUniforms)) {
        self.failure = 0;
        if (error)
            *error = self.injected;
        return nil;
    }
    return [super uploadBytes:bytes length:length offset:offset error:error];
}
- (BOOL)addResource:(id<MTLResource>)resource error:(NSError **)error
{
    if (self.failure == 2) {
        self.failure = 0;
        if (error)
            *error = self.injected;
        return NO;
    }
    return [super addResource:resource error:error];
}
- (id<MTL4RenderCommandEncoder>)beginRasterPass:(MTL4RenderPassDescriptor *)pass
                                          error:(NSError **)error
{
    if (self.failure == 3) {
        self.failure = 0;
        if (error)
            *error = self.injected;
        return nil;
    }
    return [super beginRasterPass:pass error:error];
}
@end

@interface CRCClear : NV2AMetalClear
@property(nonatomic) BOOL reference, lateFailure;
@property(nonatomic, strong) NSError *injected;
@end
@implementation CRCClear
- (BOOL)canContinueRasterPass:(MTL4RenderPassDescriptor *)pass
                       config:(const NV2AMetalClearConfig *)config
{
    return !self.reference && [super canContinueRasterPass:pass config:config];
}
- (BOOL)encodeColor:(id<MTLTexture>)color
               zeta:(id<MTLTexture>)zeta
             config:(const NV2AMetalClearConfig *)config
         rasterPass:(MTL4RenderPassDescriptor *)pass
           commands:(NV2AMetalCommands *)owner
              error:(NSError **)error
{
    BOOL ok = [super encodeColor:color
                            zeta:zeta
                          config:config
                      rasterPass:pass
                        commands:owner
                           error:error];
    if (ok && self.lateFailure) {
        self.lateFailure = NO;
        if (error)
            *error = self.injected;
        return NO;
    }
    return ok;
}
@end

typedef struct CRCUniforms {
    float color[4], depth, padding[3];
} CRCUniforms;

/* An independent native draw, not the clear shader or a CPU image substitute.
 * A writes red/depth .75/stencil 0x37, C green/.25/0x19. */
static id<MTLRenderPipelineState> crc_pipeline(MTLPixelFormat format,
                                               unsigned samples)
{
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    ld.options.mathMode = MTLMathModeSafe;
    ld.source =
        @"#include <metal_stdlib>\nusing namespace metal;\n"
         "struct U { float4 color; float depth; };\n"
         "struct V { float4 position [[position]]; float4 color; };\n"
         "vertex V crc_vertex(uint i [[vertex_id]], constant U &u "
         "[[buffer(0)]]) {\n"
         " float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};\n"
         " V v; v.position=float4(p[i],u.depth,1); v.color=u.color; return v; "
         "}\n"
         "fragment float4 crc_fragment(V v [[stage_in]]) { return v.color; }\n";
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld
                                                          error:&error];
    require(library != nil, error);
    MTL4LibraryFunctionDescriptor *v = [MTL4LibraryFunctionDescriptor new];
    MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new];
    v.library = f.library = library;
    v.name = @"crc_vertex";
    f.name = @"crc_fragment";
    MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];
    pd.vertexFunctionDescriptor = v;
    pd.fragmentFunctionDescriptor = f;
    pd.rasterSampleCount = samples;
    pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    pd.colorAttachments[0].pixelFormat = format;
    pd.colorAttachments[0].writeMask = MTLColorWriteMaskAll;
    pd.colorAttachments[0].blendingState = MTL4BlendStateDisabled;
    id<MTLRenderPipelineState> pipeline =
        [compiler newRenderPipelineStateWithDescriptor:pd
                                   compilerTaskOptions:nil
                                                 error:&error];
    require(pipeline != nil, error);
    return pipeline;
}
static MTL4RenderPassDescriptor *
crc_pass(id<MTLTexture> color, id<MTLTexture> zeta, id<MTLBuffer> query)
{
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (zeta) {
        pass.depthAttachment.texture = zeta;
        pass.depthAttachment.loadAction = MTLLoadActionLoad;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        if (zeta.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
            pass.stencilAttachment.texture = zeta;
            pass.stencilAttachment.loadAction = MTLLoadActionLoad;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
        }
    }
    pass.visibilityResultBuffer = query;
    pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    return pass;
}
static void crc_draw(MTL4RenderPassDescriptor *pass,
                     id<MTLRenderPipelineState> pipeline, BOOL last)
{
    NSError *error = nil;
    CRCUniforms u = { .color = { !last, last, 0, last ? 1 : 0 },
                      .depth = last ? .25f : .75f };
    NSUInteger offset = 0;
    id<MTLBuffer> uniforms = [commands uploadBytes:&u
                                            length:sizeof(u)
                                            offset:&offset
                                             error:&error];
    require(uniforms != nil, error);
    require([commands addResource:pass.colorAttachments[0].texture
                            error:&error] &&
                [commands addResource:pass.visibilityResultBuffer
                                error:&error] &&
                [commands keepAlive:pipeline error:&error],
            error);
    if (pass.depthAttachment.texture)
        require([commands addResource:pass.depthAttachment.texture
                                error:&error],
                error);
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 1;
    ad.initializeBindings = YES;
    id<MTL4ArgumentTable> arguments =
        [commands.device newArgumentTableWithDescriptor:ad error:&error];
    require(arguments != nil, error);
    [arguments setAddress:uniforms.gpuAddress + offset atIndex:0];
    require([commands keepAlive:arguments error:&error], error);
    MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
    ds.depthCompareFunction = MTLCompareFunctionAlways;
    ds.depthWriteEnabled = pass.depthAttachment.texture != nil;
    if (pass.stencilAttachment.texture) {
        MTLStencilDescriptor *s = [MTLStencilDescriptor new];
        s.stencilCompareFunction = MTLCompareFunctionAlways;
        s.depthStencilPassOperation = MTLStencilOperationReplace;
        ds.frontFaceStencil = ds.backFaceStencil = s;
    }
    id<MTLDepthStencilState> state =
        [commands.device newDepthStencilStateWithDescriptor:ds];
    assert(state);
    require([commands keepAlive:state error:&error], error);
    id<MTL4RenderCommandEncoder> e = [commands beginRasterPass:pass
                                                         error:&error];
    require(e != nil, error);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setRenderPipelineState:pipeline];
    [e setDepthStencilState:state];
    [e setStencilReferenceValue:last ? 0x19 : 0x37];
    [e setCullMode:MTLCullModeNone];
    [e setViewport:(MTLViewport){ 0, 0, 8, 8, 0, 1 }];
    [e setScissorRect:last ? (MTLScissorRect){ 0, 0, 2, 2 } :
                             (MTLScissorRect){ 0, 0, 8, 8 }];
    [e setVisibilityResultMode:MTLVisibilityResultModeCounting
                        offset:last ? 8 : 0];
    [e setArgumentTable:arguments atStages:MTLRenderStageVertex];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
}

static NSDictionary *crc_run(unsigned profile, BOOL reference, unsigned failure)
{
    NV2AMetalCommands *saved = commands;
    NSError *error = nil;
    CRCCommands *local = [[CRCCommands alloc] initWithError:&error];
    require(local != nil, error);
    commands = local;
    @try {
        CRCClear *clear = [[CRCClear alloc] initWithDevice:local.device
                                                     error:&error];
        require(clear != nil, error);
        clear.reference = reference;
        clear.injected = local.injected =
            [NSError errorWithDomain:@"crc.injected" code:47 userInfo:nil];
        MTLPixelFormat format =
            profile == 5 ? MTLPixelFormatB5G6R5Unorm : MTLPixelFormatRGBA8Unorm;
        MTLPixelFormat depth = profile == 1 ?
                                   MTLPixelFormatDepth16Unorm :
                               (profile == 2 || profile == 3 || profile == 4) ?
                                   MTLPixelFormatDepth32Float_Stencil8 :
                                   MTLPixelFormatInvalid;
        unsigned samples = profile == 7 ? 4 : 1;
        id<MTLTexture> color = texture(format, samples);
        id<MTLTexture> zeta =
            depth == MTLPixelFormatInvalid ? nil : texture(depth, 1);
        initialize(color, zeta, MTLClearColorMake(0, 0, 0, 0), 1, 0);
        finish();
        id<MTLBuffer> query =
            [local.device newBufferWithLength:16
                                      options:MTLResourceStorageModeShared];
        assert(query);
        memset(query.contents, 0, 16);
        MTL4RenderPassDescriptor *pass = crc_pass(color, zeta, query);
        id<MTLRenderPipelineState> pipeline = crc_pipeline(format, samples);
        NV2AMetalClearConfig c = {
            .parameter = NV097_CLEAR_SURFACE_COLOR |
                         (zeta ? NV097_CLEAR_SURFACE_Z : 0) |
                         (depth == MTLPixelFormatDepth32Float_Stencil8 ?
                              NV097_CLEAR_SURFACE_STENCIL :
                              0),
            .rect = { 2, 2, 4, 4 },
            .stencil = 0x5a,
            .uniforms = { .color = { 0, .25f, 1, 1 }, .depth = .5f }
        };
        if (profile == 3)
            c.parameter = NV097_CLEAR_SURFACE_R | NV097_CLEAR_SURFACE_B |
                          NV097_CLEAR_SURFACE_Z | NV097_CLEAR_SURFACE_STENCIL;
        if (profile == 4)
            c.parameter = NV097_CLEAR_SURFACE_STENCIL;
        if (profile == 5) {
            c.dither = YES;
            c.uniforms.color[0] = .39f;
            c.uniforms.color[1] = .43f;
            c.uniforms.color[2] = .61f;
        }
        if (profile == 6) {
            c.rect = (MTLScissorRect){ 0, 0, 8,
                                       8 }; /* Actual load-clear fallback. */
            c.uniforms.color[1] = 0;
        }
        local.submits = local.waits = 0;
        local.gate = [local.device newSharedEvent];
        assert(local.gate);
        id<MTL4CommandQueue> queue = [local valueForKey:@"queue"];
        [queue waitForEvent:local.gate value:1];
        id<MTLSharedEvent> watchdogGate = local.gate;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                         if (!watchdogGate.signaledValue)
                             watchdogGate.signaledValue = 2;
                       });
        require([local beginWithError:&error] != nil, error);
        crc_draw(pass, pipeline, NO);
        require([local sealWithError:&error], error);
        require([local beginWithError:&error] != nil, error);
        MTL4RenderPassDescriptor *snapshot = [local copyPendingRasterPass];
        assert(snapshot && snapshot != pass &&
               snapshot.visibilityResultBuffer == query &&
               snapshot.visibilityResultType == pass.visibilityResultType);
        /* Mutating the detached copy must not alter the pending parent. */
        snapshot.renderTargetWidth = 7;
        assert(![local rasterPassMatches:snapshot]);
        snapshot = [local copyPendingRasterPass];
        assert([local rasterPassMatches:snapshot]);
        BOOL continuation = [clear canContinueRasterPass:snapshot config:&c];
        assert(continuation == (!reference && profile != 6));
        if (continuation) {
            if (failure) {
                NSUInteger accepted = local.sealedBufferCount;
                local.failure = failure <= 3 ? failure : 0;
                clear.lateFailure = failure == 4;
                error = nil;
                assert(![clear encodeColor:color
                                      zeta:zeta
                                    config:&c
                                rasterPass:snapshot
                                  commands:local
                                     error:&error]);
                assert(!local.failure && !clear.lateFailure);
                /* addResource retains its established wrapper diagnostic. */
                assert(failure == 2 ?
                           [error.localizedDescription
                               isEqualToString:
                                   @"Cannot retain native clear resources"] :
                           error == local.injected);
                [local cancelUnsealed];
                assert(local.sealedBufferCount == accepted &&
                       !local.commandBuffer && !local.submits && !local.waits &&
                       !local.gate.signaledValue);
                require([local beginWithError:&error] != nil, error);
                snapshot = [local copyPendingRasterPass];
            }
            require([clear encodeColor:color
                                  zeta:zeta
                                config:&c
                            rasterPass:snapshot
                              commands:local
                                 error:&error],
                    error);
            require([local sealWithError:&error], error);
            assert(!local.submits && !local.waits && !local.gate.signaledValue);
        } else {
            /* The old caller drains the pending chain BEFORE standalone clear;
             * a producer-buffer clear here would execute before red draw A. */
            finish();
            require([local beginWithError:&error] != nil, error);
            require([clear encodeColor:color
                                  zeta:zeta
                                config:&c
                              commands:local
                                 error:&error],
                    error);
            finish();
        }
        require([local beginWithError:&error] != nil, error);
        crc_draw(pass, pipeline, YES);
        require([local submitWithError:&error], error);
        NV2AMetalSubmission *receipt = local.lastSubmitted;
        assert(receipt);
        if (continuation) {
            NSError *pendingError = nil;
            assert(!local.gate.signaledValue &&
                   ![receipt completedWithError:&pendingError] &&
                   !pendingError);
        }
        require([local waitUntilIdleWithError:&error], error);
        assert(local.gate.signaledValue == 1);
        unsigned submits = local.submits, waits = local.waits;
        require([local beginWithError:&error] != nil, error);
        id<MTLTexture> image = resolve(color);
        id<MTLBuffer> z = zeta ? read_zeta(zeta, NO) : nil;
        id<MTLBuffer> s = depth == MTLPixelFormatDepth32Float_Stencil8 ?
                              read_zeta(zeta, YES) :
                              nil;
        finish();
        NSUInteger pixelBytes = format == MTLPixelFormatB5G6R5Unorm ? 2 : 4;
        NSMutableData *pixels =
            [NSMutableData dataWithLength:8 * 8 * pixelBytes];
        [image getBytes:pixels.mutableBytes
            bytesPerRow:8 * pixelBytes
             fromRegion:MTLRegionMake2D(0, 0, 8, 8)
            mipmapLevel:0];
        if (format == MTLPixelFormatRGBA8Unorm) {
            const uint8_t *bytes = pixels.bytes;
            for (unsigned y = 0; y < 8; y++)
                for (unsigned x = 0; x < 8; x++) {
                    BOOL last = x < 2 && y < 2, hit = covered(c.rect, x, y);
                    uint8_t expected[4] = { 255, 0, 0, 0 };
                    if (last) {
                        expected[0] = 0;
                        expected[1] = 255;
                        expected[3] = 255;
                    } else if (hit) {
                        if (c.parameter & NV097_CLEAR_SURFACE_R)
                            expected[0] = 0;
                        if (c.parameter & NV097_CLEAR_SURFACE_G)
                            expected[1] =
                                (uint8_t)roundf(c.uniforms.color[1] * 255);
                        if (c.parameter & NV097_CLEAR_SURFACE_B)
                            expected[2] = 255;
                        if (c.parameter & NV097_CLEAR_SURFACE_A)
                            expected[3] = 255;
                    }
                    assert(!memcmp(bytes + (y * 8 + x) * 4, expected, 4));
                }
        }
        if (zeta) {
            for (unsigned y = 0; y < 8; y++)
                for (unsigned x = 0; x < 8; x++) {
                    BOOL last = x < 2 && y < 2, hit = covered(c.rect, x, y);
                    float expected =
                        last                                         ? .25f :
                        hit && (c.parameter & NV097_CLEAR_SURFACE_Z) ? .5f :
                                                                       .75f;
                    if (depth == MTLPixelFormatDepth16Unorm) {
                        uint16_t word;
                        memcpy(&word,
                               (const uint8_t *)z.contents + y * 256 + x * 2,
                               2);
                        assert(word == (uint16_t)roundf(expected * 65535));
                    } else {
                        float word;
                        memcpy(&word,
                               (const uint8_t *)z.contents + y * 256 + x * 4,
                               4);
                        assert(word == expected);
                        assert(((const uint8_t *)s.contents)[y * 256 + x] ==
                               (last ? 0x19 :
                                hit && (c.parameter &
                                        NV097_CLEAR_SURFACE_STENCIL) ?
                                       0x5a :
                                       0x37));
                    }
                }
        }
        uint64_t counts[2];
        memcpy(counts, query.contents, sizeof(counts));
        if (samples == 1)
            assert(counts[0] == 64 && counts[1] == 4);
        else
            assert(counts[0] && counts[1]); /* A/B exact comparison below. */
        NSMutableData *result = [pixels mutableCopy];
        /* Row padding is not initialized by a texture-to-buffer copy. */
        for (unsigned y = 0; y < 8; y++) {
            if (z)
                [result
                    appendBytes:(const uint8_t *)z.contents + y * 256
                         length:8 *
                                (depth == MTLPixelFormatDepth16Unorm ? 2 : 4)];
            if (s)
                [result appendBytes:(const uint8_t *)s.contents + y * 256
                             length:8];
        }
        [result appendBytes:counts length:sizeof(counts)];
        return
            @{@"bytes" : result,
              @"submits" : @(submits),
              @"waits" : @(waits)};
    } @finally {
        [local cancel];
        commands = saved;
    }
}
static void clear_raster_continuation_tests(void)
{
    unsigned pairs = 0;
    for (unsigned profile = 0; profile < 8; profile++) {
        if (profile == 7 && ![commands.device supportsTextureSampleCount:4]) {
            puts("Clear raster continuation: real Metal MSAA4 unavailable");
            continue;
        }
        @autoreleasepool {
            NSDictionary *reference = crc_run(profile, YES, 0);
            NSDictionary *candidate = crc_run(profile, NO, 0);
            assert([candidate[@"bytes"] isEqual:reference[@"bytes"]]);
            assert([candidate[@"submits"] unsignedIntValue] ==
                       (profile == 6 ? 3 : 1) &&
                   [candidate[@"waits"] unsignedIntValue] ==
                       (profile == 6 ? 3 : 1));
            assert([reference[@"submits"] unsignedIntValue] == 3 &&
                   [reference[@"waits"] unsignedIntValue] == 3);
            pairs++;
        }
    }
    for (unsigned failure = 1; failure <= 4; failure++) {
        @autoreleasepool {
            NSDictionary *reference = crc_run(2, YES, 0);
            NSDictionary *candidate = crc_run(2, NO, failure);
            assert([candidate[@"bytes"] isEqual:reference[@"bytes"]]);
            assert([candidate[@"submits"] unsignedIntValue] == 1 &&
                   [candidate[@"waits"] unsignedIntValue] == 1);
            pairs++;
        }
    }
    printf(
        "Clear raster continuation: %u native A/clear/C A/B pairs; color/depth/"
        "stencil/query bytes, detached pass, gated chain, accepted-prefix "
        "rollback/retry PASS\n",
        pairs);
}
