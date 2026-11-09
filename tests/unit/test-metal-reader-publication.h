/* Reader publication must include conflicting writers' execution witnesses.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_READER_PUBLICATION_H
#define TEST_METAL_READER_PUBLICATION_H
#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"
static NV2AMetalIndependentReads *publication_foreign_scope;
static NV2AMetalCommands *(*publication_original_commands)(id, SEL);
static unsigned publication_foreign_probes;
static id publication_later_writer;
static BOOL (*publication_original_contains)(id, SEL, id);
static unsigned publication_later_writer_probes;

static NV2AMetalCommands *publication_probe_commands(id object, SEL selector)
{
    if (object == publication_foreign_scope)
        publication_foreign_probes++;
    return publication_original_commands(object, selector);
}

static BOOL publication_probe_contains(id object, SEL selector, id member)
{
    if (member == publication_later_writer)
        publication_later_writer_probes++;
    return publication_original_contains(object, selector, member);
}

@interface ReaderPublicationCommands : MissingReadEventCommands
@property(nonatomic) unsigned publicationWaits;
@property(nonatomic) BOOL omitWaitError;
@property(nonatomic) id<MTLSharedEvent> laterGate;
@property(nonatomic) NV2AMetalSubmission *laterSubmission;
@property(nonatomic) unsigned laterWaits, idleWaits;
@end
@implementation ReaderPublicationCommands
- (BOOL)waitForSubmission:(NV2AMetalSubmission *)submission
                    error:(NSError **)error
{
    if (submission == _laterSubmission) {
        _laterWaits++;
        if (!_laterGate.signaledValue)
            _laterGate.signaledValue = 1;
    }
    if ([(id)submission isKindOfClass:IndependentReadReceipt.class]) {
        _publicationWaits++;
        IndependentReadReceipt *receipt = (id)submission;
        receipt.ready = YES;
        if (error)
            *error = _omitWaitError ? nil : receipt.failure;
        return !_omitWaitError && !receipt.failure;
    }
    return [super waitForSubmission:submission error:error];
}
- (BOOL)waitUntilIdleWithError:(NSError **)error
{
    _idleWaits++;
    if (_laterGate && !_laterGate.signaledValue)
        _laterGate.signaledValue = 1;
    return [super waitUntilIdleWithError:error];
}
@end
@interface ReaderPublicationSource : IndependentReadCommands
@property(nonatomic) IndependentReadReceipt *writerFeedbackAfterWait;
@end
@implementation ReaderPublicationSource
- (BOOL)waitForSubmission:(NV2AMetalSubmission *)submission
                    error:(NSError **)error
{
    if (![super waitForSubmission:submission error:error])
        return NO;
    _writerFeedbackAfterWait.ready = YES;
    return YES;
}
@end

static IndependentReadReceipt *
reader_delayed_feedback(NV2AMetalCommands *commands)
{
    IndependentReadReceipt *receipt = [IndependentReadReceipt new];
    receipt.nativeSubmission = commands.lastSubmitted;
    return receipt;
}

static void reader_collection_prefix_test(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalCommands *target =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    IndependentReadCommands *source =
        [[IndependentReadCommands alloc] initWithDevice:device error:&error];
    id<MTLBuffer> ram = [device newBufferWithLength:4096
                                           options:MTLResourceStorageModeShared];
    require(target && source && ram, error);
    memset(ram.contents, 0x44, ram.length);
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:target vram:ram
                                           didWriteVRAM:nil error:&error];
    require(cache != nil, error);
    IndependentReadReceipt *readers[2];
    IndependentReadReceipt *writers[2];
    id<MTLBuffer> bytes[2];
    NV2AMetalSurfaceRecording *tokens[2];
    for (unsigned i = 0; i < 2; i++) {
        id<MTLBuffer> copy = nil;
        NV2AMetalIndependentReads *reads = gpu_dep_read(cache, source, 64,
                                                        &copy);
        bytes[i] = copy;
        require([source waitForSubmission:source.lastSubmitted error:&error],
                error);
        readers[i] = reader_delayed_feedback(source);
        [reads setValue:readers[i] forKey:@"submission"];
    }
    NSArray *entries = [cache valueForKey:@"submissions"];
    for (unsigned i = 0; i < 2; i++) {
        gpu_dep_write(cache, 64, 5 + i);
        tokens[i] = cache.recording;
        require([cache submitWithError:&error] &&
                    [target waitForSubmission:target.lastSubmitted error:&error],
                error);
        writers[i] = reader_delayed_feedback(target);
        [entries[i] setValue:writers[i] forKey:@"submission"];
    }
    readers[0].ready = writers[0].ready = YES;
    id first = entries[0], second = entries[1];
    NSArray *firstWitnesses = [first valueForKey:@"readWitnesses"];
    NSArray *secondWitnesses = [second valueForKey:@"readWitnesses"];
    assert(firstWitnesses.count == 2 && secondWitnesses.count == 2 &&
           [firstWitnesses[0] valueForKey:@"observed"] &&
           [firstWitnesses[0] valueForKey:@"observed"] ==
               [firstWitnesses[1] valueForKey:@"observed"] &&
           [secondWitnesses[0] valueForKey:@"observed"] ==
               [secondWitnesses[1] valueForKey:@"observed"] &&
           [firstWitnesses[0] valueForKey:@"observed"] !=
               [secondWitnesses[0] valueForKey:@"observed"] &&
           [[firstWitnesses[0] valueForKey:@"observedOffset"] unsignedLongValue] == 0 &&
           [[firstWitnesses[1] valueForKey:@"observedOffset"] unsignedLongValue] == 8);
    SEL selector = @selector(completedWithError:);
    Method feedback = class_getInstanceMethod([first class], selector);
    assert(feedback);
    BOOL (*original)(id, SEL, NSError **) =
        (void *)method_getImplementation(feedback);
    __block unsigned firstChecks = 0, secondChecks = 0;
    IMP spy = imp_implementationWithBlock(^BOOL(id writer, NSError **failure) {
        firstChecks += writer == first;
        secondChecks += writer == second;
        return original(writer, selector, failure);
    });
    method_setImplementation(feedback, spy);
    for (unsigned i = 0; i < 32; i++)
        require([cache collectCompletedWithError:&error], error);
    method_setImplementation(feedback, (IMP)original);
    assert(imp_removeBlock(spy));
    /* The first writer is also the retirement head on every poll. */
    assert(firstChecks == 33 && secondChecks == 32 &&
           !tokens[0].completed && !tokens[1].completed);
    assert(![firstWitnesses[0] valueForKey:@"observed"] &&
           [firstWitnesses[1] valueForKey:@"observed"] &&
           [secondWitnesses[0] valueForKey:@"observed"] &&
           [secondWitnesses[1] valueForKey:@"observed"]);
    assert(gpu_dep_word(bytes[0], 0) == UINT64_C(0x4444444444444444) &&
           gpu_dep_word(bytes[1], 0) == UINT64_C(0x4444444444444444));
    readers[1].ready = writers[1].ready = YES;
    require([cache collectCompletedWithError:&error], error);
    assert(tokens[0].completed && tokens[1].completed &&
           gpu_dep_word(ram, 64) == 6);
    assert(![firstWitnesses[1] valueForKey:@"observed"] &&
           ![secondWitnesses[0] valueForKey:@"observed"] &&
           ![secondWitnesses[1] valueForKey:@"observed"]);
    require([cache discardForRestoreWithError:&error], error);
    checks++;
    puts("Reader witness collection: one reader-side check of the confirmed "
         "writer across 32 polls; the later writer still gates release PASS");
    puts("Reader witness lifetime: confirmed marker releases its buffer while "
         "the writer remains tracked; remaining markers validate on retirement PASS");
}

static void reader_witness_page_test(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalCommands *target =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    IndependentReadCommands *source =
        [[IndependentReadCommands alloc] initWithDevice:device error:&error];
    id<MTLBuffer> ram = [device newBufferWithLength:4096
                                           options:MTLResourceStorageModeShared];
    require(target && source && ram, error);
    memset(ram.contents, 0x44, ram.length);
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:target vram:ram
                                           didWriteVRAM:nil error:&error];
    require(cache != nil, error);
    NSMutableArray<IndependentReadReceipt *> *receipts = [NSMutableArray new];
    NSMutableArray<NV2AMetalIndependentReads *> *scopes = [NSMutableArray new];
    for (unsigned i = 0; i < 65; i++) {
        id<MTLBuffer> old = nil;
        NV2AMetalIndependentReads *reads = gpu_dep_read(cache, source, i * 8,
                                                        &old);
        require([source waitForSubmission:source.lastSubmitted error:&error],
                error);
        assert(gpu_dep_word(old, 0) == UINT64_C(0x4444444444444444));
        IndependentReadReceipt *receipt = reader_delayed_feedback(source);
        [reads setValue:receipt forKey:@"submission"];
        [receipts addObject:receipt];
        [scopes addObject:reads];
    }
    /* The last reader makes all earlier receipts part of the accepted queue
     * prefix. The next section adds witnesses for those readers' own spans. */
    gpu_dep_write(cache, 64 * 8, 19);
    Class commandClass = object_getClass(target.commandBuffer);
    require([cache checkpointWithError:&error], error);
    NSArray *pending = [cache valueForKey:@"pendingReadWitnesses"];
    NSOrderedSet *dependencies = [cache valueForKey:@"pendingDependencies"];
    assert(pending.count == 1 && [dependencies.array isEqualToArray:scopes]);
    id<MTLBuffer> firstPage = [pending[0] valueForKey:@"observed"];
    SEL selector = @selector(computeCommandEncoder);
    Method method = class_getInstanceMethod(commandClass, selector);
    assert(method);
    class_addMethod(commandClass, selector, method_getImplementation(method),
                    method_getTypeEncoding(method));
    method = class_getInstanceMethod(commandClass, selector);
    id<MTL4ComputeCommandEncoder> (*original)(id, SEL) =
        (void *)method_getImplementation(method);
    __block unsigned attempts = 0;
    IMP spy = imp_implementationWithBlock(^id<MTL4ComputeCommandEncoder>(id buffer) {
        return ++attempts == 1 ? nil : original(buffer, selector);
    });
    method_setImplementation(method, spy);
    assert(![cache prepareGPUWriteAtAddress:0 length:64 * 8 error:&error] &&
           error && pending.count == 1 && attempts == 1);
    [cache cancel];
    error = nil;
    require([cache prepareGPUWriteAtAddress:0 length:64 * 8 error:&error], error);
    assert(pending.count == 65 && attempts == 2);
    [cache cancel];
    assert(pending.count == 1);
    require([cache prepareGPUWriteAtAddress:0 length:64 * 8 error:&error], error);
    require([cache prepareGPUWriteAtAddress:0 length:64 * 8 error:&error], error);
    method_setImplementation(method, (IMP)original);
    assert(imp_removeBlock(spy));
    assert(pending.count == 65 && attempts == 3 &&
           [dependencies.array isEqualToArray:scopes]);
    id<MTLBuffer> secondPage = [pending[64] valueForKey:@"observed"];
    assert(firstPage && secondPage && firstPage != secondPage);
    for (NSUInteger i = 0; i < pending.count; i++) {
        assert([pending[i] valueForKey:@"observed"] ==
                   (i < 64 ? firstPage : secondPage) &&
               [[pending[i] valueForKey:@"observedOffset"] unsignedLongValue] ==
                   (i % 64) * sizeof(uint64_t));
    }
    require([cache submitWithError:&error] &&
                [target waitForSubmission:target.lastSubmitted error:&error],
            error);
    NSArray *submissions = [cache valueForKey:@"submissions"];
    NSOrderedSet *submitted = [submissions[0] valueForKey:@"dependencies"];
    assert(!dependencies.count && [submitted.array isEqualToArray:scopes]);
    for (NSUInteger i = 0; i < 64; i++)
        assert(gpu_dep_word(firstPage, i * sizeof(uint64_t)) == 1);
    assert(gpu_dep_word(secondPage, 0) == 1 && gpu_dep_word(ram, 64 * 8) == 19);
    for (IndependentReadReceipt *receipt in receipts)
        receipt.ready = YES;
    require([cache collectCompletedWithError:&error] &&
                [cache discardForRestoreWithError:&error],
            error);
    checks++;
    puts("Reader witness pages: 65 distinct GPU marks in two buffers, "
         "sealed prefix intact after suffix cancellation and retry PASS");
    puts("Reader witness encoder: 64 marks use one encoder; failed creation "
         "publishes no witnesses and preserves the sealed prefix PASS");
    puts("Reader dependency membership: repeated range reuses all 65 scopes "
         "and markers; submitted feedback order survives batch reset PASS");
}

#include "test-metal-raster-feedback.h"
static NV2AMetalSubmission *publication_full_only_receipt;
static BOOL (*publication_original_separate)(id, SEL);
static BOOL publication_full_only(id receipt, SEL selector)
{
    return receipt == publication_full_only_receipt ? NO :
        publication_original_separate(receipt, selector);
}

static void reader_producer_publication_tests(id<MTLDevice> device)
{
    for (unsigned count = 1; count <= 2; count++)
        for (unsigned poll = 0; poll < 5; poll++) {
            if (count == 2 && poll == 2)
                continue;
            BOOL fullControl = poll == 2 || poll == 4;
            NSError *error = nil;
            NV2AMetalCommands *target = [[NV2AMetalCommands alloc]
                initWithDevice:device error:&error];
            NV2AMetalCommands *source = [[NV2AMetalCommands alloc]
                initWithDevice:device error:&error];
            id<MTLBuffer> ram = [device newBufferWithLength:16384
                options:MTLResourceStorageModeShared];
            require(target && source && ram, error);
            memset(ram.contents, 0x44, ram.length);
            NV2AMetalSurfaceCache *cache = [[NV2AMetalSurfaceCache alloc]
                initWithCommands:target vram:ram didWriteVRAM:nil error:&error];
            require(cache != nil, error);
            Ivar queueIvar = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
            id<MTL4CommandQueue> sourceQueue = object_getIvar(source, queueIvar);
            id<MTLSharedEvent> readGate = [device newSharedEvent];
            ReaderRasterFeedbackGate *rasterGate = [ReaderRasterFeedbackGate new];
            BOOL failRaster = count == 2 && (poll == 1 || poll == 3);
            if (failRaster)
                rasterGate.injectedFailure = [NSError errorWithDomain:@"test.late-raster"
                    code:91 userInfo:nil];
            assert(readGate && rasterGate);
            [sourceQueue waitForEvent:readGate value:1];
            NV2AMetalIndependentReads *readers[2];
            NV2AMetalSubmission *receipts[2];
            id<MTLBuffer> copies[2];
            for (unsigned i = 0; i < count; i++) {
                NV2AMetalVRAMReadSpan spans[] = { { 64 + i * 64, 8 }, { 4160, 8 } };
                NV2AMetalIndependentReads *reader = nil;
                require([cache tryBeginIndependentReads:spans count:2 commands:source
                    reads:&reader error:&error] && reader, error);
                readers[i] = reader;
                copies[i] = gpu_dep_copy(source, ram, spans[0].address, nil, 0);
                gpu_dep_copy(source, ram, spans[1].address, copies[i], 0);
                require([cache submitIndependentReads:readers[i] error:&error], error);
                receipts[i] = source.lastSubmitted;
            }
            gpu_dep_write(cache, 4160, UINT64_C(0x9999999999999999));
            NV2AMetalSurfaceRecording *writer = cache.recording;
            __weak NSObject *lifetime;
            @autoreleasepool {
                NSObject *retained = [NSObject new];
                lifetime = retained;
                require([target keepAlive:retained error:&error], error);
            }
            MTLTextureDescriptor *td = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                width:4 height:4 mipmapped:NO];
            td.storageMode = MTLStorageModeShared;
            td.usage = MTLTextureUsageRenderTarget;
            id<MTLTexture> color = [device newTextureWithDescriptor:td];
            assert(color);
            const uint32_t zero[16] = { 0 };
            [color replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0
                      withBytes:zero bytesPerRow:16];
            require([target addResource:color error:&error], error);
            MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
            pass.colorAttachments[0].texture = color;
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            NV2AMetalPixelShader *pixel = [[NV2AMetalPixelShader alloc]
                initWithDevice:device colorFormat:MTLPixelFormatRGBA8Unorm
                depthFormat:MTLPixelFormatInvalid sampleCount:1 error:&error];
            require(pixel != nil, error);
            NV2AMetalVertex point = { 0 };
            point.clip[2] = .5f;
            point.clip[3] = 1;
            point.point_size = 1;
            point.screen[0] = point.screen[1] = 2;
            point.color[0][1] = point.color[0][3] = 1;
            id<MTLBuffer> vertices = [device newBufferWithBytes:&point length:sizeof(point)
                options:MTLResourceStorageModeShared];
            assert(vertices);
            NV2AMetalPixelUniforms u = { 0 };
            u.combiner.final_inputs[0] = PS_REGISTER_V0;
            u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
            u.smooth_shading = 1;
            u.depth_format = NV2AMetalPixelDepthD24;
            u.surface_scale[0] = u.surface_scale[1] = 1;
            u.clip_range[1] = u.clip_range[3] = 16777215;
            u.clip_regions[0][2] = u.clip_regions[0][3] = 4;
            for (unsigned k = 0; k < 4; k++) {
                u.textures[k].dimension = 2;
                u.textures[k].scale = 1;
            }
            NV2AMetalDrawConfig config = { 0 };
            config.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE | NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
            NV2AMetalDrawState *state = [[NV2AMetalDrawState alloc]
                initWithDevice:device config:&config error:&error];
            require(state != nil, error);
            NV2AMetalPixelTexture textures[4] = { 0 };
            id<MTL4RenderCommandEncoder> raster = [target beginRasterPass:pass error:&error];
            require(raster != nil, error);
            [raster barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll
                visibilityOptions:MTL4VisibilityOptionDevice];
            require([pixel encodeVertices:vertices offset:0 count:1 primitive:MTLPrimitiveTypePoint
                uniforms:&u textures:textures pass:pass drawState:state
                rasterClass:NV2AMetalPixelRasterDirectPoint ignorePolygonCulling:NO
                renderEncoder:raster commands:target error:&error], error);
            [raster barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll
                visibilityOptions:MTL4VisibilityOptionDevice];
            [raster endEncoding];
            publication_feedback_gate = rasterGate;
            publication_feedback_handlers = 0;
            Method feedback = class_getInstanceMethod(MTL4CommitOptions.class,
                @selector(addFeedbackHandler:));
            assert(feedback);
            publication_original_feedback = (void *)method_setImplementation(feedback,
                (IMP)publication_split_feedback);
            require([cache submitWithError:&error], error);
            method_setImplementation(feedback, (IMP)publication_original_feedback);
            assert(publication_feedback_handlers == 2 && writer.submitted && !writer.completed);
            id entry = [writer valueForKey:@"submissionEntry"];
            assert([[entry valueForKey:@"readWitnesses"] count] == count);
            for (unsigned i = 0; i < count; i++)
                assert(![[readers[i] valueForKey:@"retired"] boolValue] &&
                       [readers[i] valueForKey:@"lastWitnessWriter"] == entry);
            publication_feedback_gate = nil;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ readGate.signaledValue = 1; });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                  [rasterGate releaseFeedback];
                });
            Method separate = NULL;
            if (poll == 2) {
                publication_full_only_receipt = target.lastSubmitted;
                separate = class_getInstanceMethod(NV2AMetalSubmission.class,
                    @selector(hasSeparateProducerFeedback));
                publication_original_separate = (void *)method_setImplementation(separate,
                    (IMP)publication_full_only);
            }
            if (poll >= 3) {
                require(poll == 3 ? [cache waitForProducersOfRecording:writer error:&error] :
                                   [cache waitForRecording:writer error:&error], error);
                assert(writer.completed == fullControl);
                require([cache completeIndependentReads:readers[count - 1] error:&error], error);
            } else if (poll == 1) {
                for (unsigned i = 0; i < count; i++)
                    require([source waitForSubmission:receipts[i] error:&error], error);
                require([target waitForProducersOfSubmission:target.lastSubmitted error:&error] &&
                        [cache collectCompletedWithError:&error], error);
            } else {
                require([cache completeIndependentReads:readers[count - 1] error:&error], error);
            }
            if (poll == 2) {
                method_setImplementation(separate, (IMP)publication_original_separate);
                publication_full_only_receipt = nil;
            }
            require([rasterGate waitForNativeFeedback], error);
            BOOL closedRaster = !rasterGate.delivered;
            BOOL fullPending = ![target.lastSubmitted completedWithError:&error] && !error;
            BOOL producerReady = [target.lastSubmitted completedProducersWithError:&error] && !error;
            if (!(closedRaster == !fullControl && fullPending == !fullControl &&
                  producerReady && lifetime && writer.completed == fullControl)) {
                fprintf(stderr, "Producer publication count=%u poll=%u feedbackHeld=%d fullPending=%d producer=%d lifetime=%d writerComplete=%d\n",
                    count, poll, closedRaster, fullPending, producerReady,
                    lifetime != nil, writer.completed);
                abort();
            }
            for (unsigned i = 0; i < count; i++)
                assert([[readers[i] valueForKey:@"retired"] boolValue] &&
                       gpu_dep_word(copies[i], 0) == UINT64_C(0x4444444444444444));
            require([cache resolveCPUAccessAtAddress:64 length:8 write:YES error:&error], error);
            assert(rasterGate.delivered == fullControl && writer.completed == fullControl);
            assert(gpu_dep_word(ram, 4160) == UINT64_C(0x9999999999999999));
            [rasterGate releaseFeedback];
            BOOL idle = [cache waitUntilIdleWithError:&error];
            if (failRaster) {
                assert(!idle && error == rasterGate.injectedFailure && !writer.completed && !lifetime);
                error = nil;
                assert(![cache collectCompletedWithError:&error] && error == rasterGate.injectedFailure);
            } else {
                require(idle, error);
                assert(writer.completed && !lifetime);
            }
            require([source waitUntilIdleWithError:&error], error);
            uint32_t rgba[16];
            [color getBytes:rgba bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
            unsigned green = 0;
            for (unsigned i = 0; i < 16; i++)
                green += rgba[i] == 0xff00ff00u;
            assert(green == 1);
        }
    puts("Reader producer publication:9 native single/shared-reader explicit/poll/recording-producer/full-feedback-control cases;"
         "compute witnesses release readers and unrelated CPU writes with raster feedback held;"
         "full receipt,Surface ownership and resource lifetime remain pending until raster feedback;"
         "injected late raster failure remains sticky after reader release;exact green pixel PASS");
}

static void recording_producer_prefix_tests(id<MTLDevice> device)
{
    for (unsigned mode = 0; mode < 3; mode++) {
        NSError *error = nil;
        ReaderPublicationCommands *commands = [[ReaderPublicationCommands alloc]
            initWithDevice:device error:&error];
        id<MTLBuffer> ram = [device newBufferWithLength:65536
            options:MTLResourceStorageModeShared];
        require(commands && ram, error);
        NV2AMetalSurfaceCache *cache = [[NV2AMetalSurfaceCache alloc]
            initWithCommands:commands vram:ram didWriteVRAM:nil error:&error];
        require(cache != nil, error);
        NV2AMetalSurfaceRecording *tokens[3];
        CountedIndependentReadReceipt *receipts[3];
        for (unsigned i = 0; i < 3; i++) {
            gpu_dep_write(cache, i * 8, i + 1);
            tokens[i] = cache.recording;
            require([cache submitWithError:&error] &&
                    [commands waitForSubmission:commands.lastSubmitted error:&error], error);
            receipts[i] = [CountedIndependentReadReceipt new];
            receipts[i].nativeSubmission = commands.lastSubmitted;
            NSArray *entries = [cache valueForKey:@"submissions"];
            [entries.lastObject setValue:receipts[i] forKey:@"submission"];
        }
        NSError *first = [NSError errorWithDomain:@"test.producer-prefix.first" code:1 userInfo:nil];
        NSError *second = [NSError errorWithDomain:@"test.producer-prefix.second" code:2 userInfo:nil];
        receipts[0].ready = mode == 2;
        receipts[0].failure = mode == 1 ? first : nil;
        receipts[1].ready = mode != 2;
        receipts[1].failure = mode ? second : nil;
        receipts[2].failure = second;
        require([cache prepareGPUReadAtAddress:49152 length:4 error:&error], error);
        NV2AMetalSurfaceRecording *open = cache.recording;
        BOOL ok = [cache waitForProducersOfRecording:tokens[1] error:&error];
        assert(ok == !mode && commands.publicationWaits == 1 &&
               !receipts[2].polls && !receipts[2].ready && !tokens[2].completed &&
               cache.recording == open && !open.submitted);
        if (ok) {
            assert(tokens[0].completed && tokens[1].completed &&
                   tokens[0].producersCompleted && tokens[1].producersCompleted);
            receipts[2].failure = nil;
            receipts[2].ready = YES;
            require([cache collectCompletedWithError:&error], error);
        } else {
            assert(error == (mode == 1 ? first : second) &&
                   !tokens[1].producersCompleted && !tokens[1].completed);
        }
        [cache cancel];
        cache = nil;
        require([commands waitUntilIdleWithError:&error], error);
    }
    checks += 3;
    puts("Recording producer prefix:3 native delayed-earlier/ready-later error cases;"
         "earlier full feedback has priority, later feedback and open recording untouched PASS");
}

static void reader_publication_tests(id<MTLDevice> device)
{
    reader_producer_publication_tests(device);
    recording_producer_prefix_tests(device);
    reader_collection_prefix_test(device);
    reader_witness_page_test(device);
    unsigned cases = 0;
    for (unsigned boundary = 0; boundary < 2; boundary++)
    for (unsigned mode = 0; mode < 7; mode++) {
        @autoreleasepool {
            NSError *error = nil;
            BOOL badOrder = mode < 3, laterReader = mode == 1;
            BOOL otherHead = mode == 2 || mode == 3;
            ReaderPublicationCommands *target =
                [[ReaderPublicationCommands alloc] initWithDevice:device
                                                            error:&error];
            target.omitReadEvent = badOrder;
            target.omitWaitError = mode == 5;
            IndependentReadCommands *source =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                          error:&error];
            IndependentReadCommands *other =
                [[IndependentReadCommands alloc] initWithDevice:device
                                                          error:&error];
            id<MTLBuffer> ram =
                [device newBufferWithLength:65536
                                    options:MTLResourceStorageModeShared];
            require(target && source && other && ram, error);
            memset(ram.contents, 0x44, ram.length);
            NV2AMetalSurfaceCache *cache =
                [[NV2AMetalSurfaceCache alloc] initWithCommands:target
                                                           vram:ram
                                                   didWriteVRAM:nil
                                                          error:&error];
            require(cache != nil, error);
            IndependentReadReceipt *head = nil;
            NV2AMetalIndependentReads *otherScope = nil;
            if (otherHead) {
                id<MTLBuffer> bytes = nil;
                otherScope = gpu_dep_read(cache, other, 24000, &bytes);
                require([other waitForSubmission:other.lastSubmitted
                                           error:&error],
                        error);
                head = reader_delayed_feedback(other);
                [otherScope setValue:head forKey:@"submission"];
            }
            if (badOrder)
                gpu_dep_gate(source);
            id<MTLBuffer> old = nil;
            NV2AMetalIndependentReads *reads =
                gpu_dep_read(cache, source, 32764, &old);
            if (!badOrder) {
                require([source waitForSubmission:source.lastSubmitted
                                            error:&error],
                        error);
                [reads setValue:reader_delayed_feedback(source)
                         forKey:@"submission"];
            }
            gpu_dep_write(cache, 32764, UINT64_C(0x7777777777777777));
            NV2AMetalSurfaceRecording *written = cache.recording;
            require([cache submitWithError:&error] &&
                        [target waitForSubmission:target.lastSubmitted
                                            error:&error],
                    error);
            NSArray *submitted = [cache valueForKey:@"submissions"];
            assert(submitted.count == 1);
            IndependentReadReceipt *writer = reader_delayed_feedback(target);
            NSError *writerError =
                (mode == 4 || mode == 6) ?
                    [NSError errorWithDomain:@"test.reader.writer"
                                                code:77
                                            userInfo:nil] :
                            nil;
            writer.failure = writerError;
            writer.ready = mode == 6;
            [submitted[0] setValue:writer forKey:@"submission"];
            if (badOrder) {
                assert(!source.gate.signaledValue &&
                       ![source.lastSubmitted completedWithError:NULL]);
                source.gate.signaledValue = 1;
                require([source waitForSubmission:source.lastSubmitted
                                            error:&error],
                        error);
                assert(gpu_dep_word(old, 0) == UINT64_C(0x7777777777777777));
            } else {
                assert(gpu_dep_word(old, 0) == UINT64_C(0x4444444444444444));
            }
            NV2AMetalIndependentReads *requested = reads;
            if (laterReader) {
                id<MTLBuffer> bytes = nil;
                requested = gpu_dep_read(cache, source, 48000, &bytes);
                require([source waitForSubmission:source.lastSubmitted
                                            error:&error],
                        error);
                assert(gpu_dep_word(bytes, 0) == UINT64_C(0x4444444444444444));
            }
            other.waits = 0;
            error = nil;
            Method commandsMethod = class_getInstanceMethod(
                NV2AMetalIndependentReads.class, sel_registerName("commands"));
            assert(commandsMethod);
            publication_foreign_scope = otherScope;
            publication_foreign_probes = 0;
            publication_original_commands = (void *)method_setImplementation(
                commandsMethod, (IMP)publication_probe_commands);
            BOOL ok = boundary ? [cache waitForProducersOfRecording:written error:&error] :
                                 [cache completeIndependentReads:requested error:&error];
            method_setImplementation(commandsMethod,
                                     (IMP)publication_original_commands);
            publication_foreign_scope = nil;
            assert(!publication_foreign_probes);
            assert(ok == (mode == 3));
            assert(writer.ready && target.publicationWaits == (mode != 6) &&
                   !other.waits && (!head || !head.ready));
            if (ok) {
                assert(!error && written.completed);
                head.ready = YES;
                require([cache collectCompletedWithError:&error] &&
                            [cache discardForRestoreWithError:&error],
                        error);
            } else {
                assert(error && !written.completed &&
                       !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 60000,
                                                  4, NO));
                if (writerError)
                    assert(error == writerError);
                if (badOrder)
                    assert([error.localizedDescription
                        containsString:@"GPU readers"]);
                NSError *failure = error;
                assert(![cache completeIndependentReads:requested
                                                  error:&error] &&
                       error == failure);
            }
            cache = nil;
            require([source waitUntilIdleWithError:&error] &&
                        [other waitUntilIdleWithError:&error] &&
                        [target waitUntilIdleWithError:&error],
                    error);
            cases++;
        }
    }
    for (unsigned submitted = 0; submitted < 8; submitted++) {
        @autoreleasepool {
            NSError *error = nil;
            ReaderPublicationCommands *target =
                [[ReaderPublicationCommands alloc] initWithDevice:device
                                                            error:&error];
            ReaderPublicationSource *source =
                [[ReaderPublicationSource alloc] initWithDevice:device
                                                          error:&error];
            id<MTLBuffer> ram =
                [device newBufferWithLength:65536
                                    options:MTLResourceStorageModeShared];
            require(target && source && ram, error);
            memset(ram.contents, 0x44, ram.length);
            NV2AMetalSurfaceCache *cache =
                [[NV2AMetalSurfaceCache alloc] initWithCommands:target
                                                           vram:ram
                                                   didWriteVRAM:nil
                                                          error:&error];
            require(cache != nil, error);
            IndependentReadReceipt *otherFeedback = nil;
            id<MTLBuffer> earlierBytes = nil;
            CountedIndependentReadReceipt *firstWriterFeedback = nil;
            CountedIndependentReadReceipt *secondWriterFeedback = nil;
            CountedIndependentReadReceipt *currentFeedback = nil;
            if (submitted >= 2) {
                IndependentReadCommands *other =
                    [[IndependentReadCommands alloc] initWithDevice:device
                                                              error:&error];
                require(other != nil, error);
                id<MTLBuffer> otherBytes = nil;
                NV2AMetalIndependentReads *head =
                    gpu_dep_read(cache, other, 24000, &otherBytes);
                require([other waitForSubmission:other.lastSubmitted
                                           error:&error],
                        error);
                otherFeedback = reader_delayed_feedback(other);
                [head setValue:otherFeedback forKey:@"submission"];
                NV2AMetalIndependentReads *earlier =
                    gpu_dep_read(cache, source, 32764, &earlierBytes);
                require([source waitForSubmission:source.lastSubmitted
                                             error:&error],
                        error);
                [earlier setValue:reader_delayed_feedback(source)
                           forKey:@"submission"];
            }
            id<MTLBuffer> old = nil;
            NV2AMetalIndependentReads *reads =
                gpu_dep_read(cache, source, 32764, &old);
            require([source waitForSubmission:source.lastSubmitted
                                        error:&error],
                    error);
            if (submitted >= 6) {
                currentFeedback = [CountedIndependentReadReceipt new];
                currentFeedback.nativeSubmission = source.lastSubmitted;
                [reads setValue:currentFeedback forKey:@"submission"];
            } else {
                [reads setValue:reader_delayed_feedback(source)
                         forKey:@"submission"];
            }
            gpu_dep_write(cache, 32764, UINT64_C(0x7777777777777777));
            NV2AMetalSurfaceRecording *writer = cache.recording;
            NV2AMetalSurfaceRecording *secondWriter = nil;
            id<MTLBuffer> laterBytes = nil;
            NV2AMetalSurfaceRecording *laterToken = nil;
            NV2AMetalSubmission *laterSubmission = nil;
            id laterWriter = nil;
            if (submitted) {
                require([cache submitWithError:&error] &&
                            [target waitForSubmission:target.lastSubmitted
                                                error:&error],
                        error);
                NSArray *entries = [cache valueForKey:@"submissions"];
                firstWriterFeedback = [CountedIndependentReadReceipt new];
                firstWriterFeedback.nativeSubmission = target.lastSubmitted;
                [entries[0] setValue:firstWriterFeedback forKey:@"submission"];
                if (submitted == 4)
                    [entries[0] setValue:@(NSUIntegerMax)
                                  forKey:@"queuePosition"];
                if (submitted >= 2) {
                    gpu_dep_write(cache, 32764, UINT64_C(0x9999999999999999));
                    secondWriter = cache.recording;
                    require([cache submitWithError:&error] &&
                                [target waitForSubmission:target.lastSubmitted
                                                    error:&error],
                            error);
                    assert(entries.count == 2);
                    secondWriterFeedback = [CountedIndependentReadReceipt new];
                    secondWriterFeedback.nativeSubmission = target.lastSubmitted;
                    [entries[1] setValue:secondWriterFeedback
                                  forKey:@"submission"];
                }
                target.laterGate = [device newSharedEvent];
                id<MTL4CommandQueue> queue = object_getIvar(
                    target, class_getInstanceVariable(NV2AMetalCommands.class,
                                                      "_queue"));
                [queue waitForEvent:target.laterGate value:1];
                require([cache prepareGPUReadAtAddress:60000
                                                length:8
                                                 error:&error],
                        error);
                laterBytes = gpu_dep_copy(target, ram, 60000, nil, 0);
                laterToken = cache.recording;
                require([cache submitWithError:&error], error);
                laterSubmission = target.lastSubmitted;
                target.laterSubmission = laterSubmission;
                laterWriter = entries.lastObject;
                require([cache prepareGPUReadAtAddress:61000
                                                length:8
                                                 error:&error],
                        error);
                gpu_dep_copy(target, ram, 61000, nil, 0);
            }
            id recording = target.commandBuffer;
            uint64_t serial = target.recordingSerial;
            NV2AMetalSurfaceRecording *open = cache.recording;
            BOOL firstWriterReady = submitted == 3;
            BOOL secondWriterReady = submitted >= 4;
            BOOL writerFinishesDuringRead = submitted == 7;
            unsigned expectedWaits =
                MIN(submitted, 2u) - firstWriterReady - secondWriterReady -
                writerFinishesDuringRead;
            if (firstWriterReady) {
                firstWriterFeedback.ready = YES;
                require([cache collectCompletedWithError:&error], error);
                assert(!writer.completed && firstWriterFeedback.polls);
            }
            if (secondWriterReady)
                secondWriterFeedback.ready = YES;
            if (writerFinishesDuringRead)
                source.writerFeedbackAfterWait = firstWriterFeedback;
            firstWriterFeedback.polls = secondWriterFeedback.polls = 0;
            if (submitted == 5) {
                firstWriterFeedback.failure =
                    [NSError errorWithDomain:@"test.reader.earlier-writer"
                                        code:81 userInfo:nil];
                secondWriterFeedback.failure =
                    [NSError errorWithDomain:@"test.reader.later-writer"
                                        code:82 userInfo:nil];
                assert(![cache completeIndependentReads:reads error:&error] &&
                       error == firstWriterFeedback.failure &&
                       target.publicationWaits == 1 && !target.laterWaits &&
                       !target.laterGate.signaledValue && !writer.completed &&
                       !secondWriter.completed && cache.recording == open);
                [cache cancel];
                target.laterGate.signaledValue = 1;
                require([target waitUntilIdleWithError:&error], error);
                cases++;
                continue;
            }
            Method contains = class_getInstanceMethod(
                object_getClass([NSHashTable hashTableWithOptions:
                    NSPointerFunctionsObjectPointerPersonality]),
                @selector(containsObject:));
            assert(contains);
            publication_later_writer = laterWriter;
            publication_later_writer_probes = 0;
            publication_original_contains = (void *)method_setImplementation(
                contains, (IMP)publication_probe_contains);
            BOOL completed;
            if (currentFeedback) {
                source.waits = currentFeedback.polls = 0;
                completed = [cache waitForSubmission:(id)secondWriterFeedback
                                               error:&error];
                /* Both writer waits and retirement reuse the first result. */
                assert(currentFeedback.polls == 1 && source.waits == 2);
            } else {
                completed = [cache completeIndependentReads:reads error:&error];
            }
            method_setImplementation(contains, (IMP)publication_original_contains);
            publication_later_writer = nil;
            require(completed, error);
            assert(!publication_later_writer_probes);
            assert(gpu_dep_word(old, 0) == UINT64_C(0x4444444444444444) &&
                   target.commandBuffer == recording &&
                   target.recordingSerial == serial &&
                   cache.recording == open && !open.submitted &&
                   !open.cancelled && !target.laterWaits && !target.idleWaits &&
                   target.publicationWaits == expectedWaits);
            if (submitted) {
                assert(writer.completed && !laterToken.completed &&
                       !target.laterGate.signaledValue &&
                       ![laterSubmission completedWithError:NULL] &&
                       !gpu_dep_word(laterBytes, 0));
                if (secondWriter) {
                    /* A bounded surface wait retires its confirmed prefix
                     * directly; explicit reader completion still confirms
                     * writer feedback before checking the read witnesses. */
                    assert(!otherFeedback.ready &&
                           firstWriterFeedback.polls ==
                               (firstWriterReady ? 0u :
                                currentFeedback ? 1u : 2u) &&
                           secondWriterFeedback.polls ==
                               (secondWriterReady ? 1u : 2u) &&
                           gpu_dep_word(earlierBytes, 0) ==
                               UINT64_C(0x4444444444444444) &&
                           secondWriter.completed &&
                           gpu_dep_word(ram, 32764) ==
                               UINT64_C(0x9999999999999999));
                    require([cache completeIndependentReads:reads error:&error],
                            error);
                    assert(!currentFeedback || currentFeedback.polls == 1);
                    assert(target.publicationWaits == expectedWaits &&
                           !target.laterWaits &&
                           !target.laterGate.signaledValue);
                    otherFeedback.ready = YES;
                }
                [cache cancel];
                assert(open.cancelled);
                target.laterGate.signaledValue = 1;
                require([cache waitForSubmission:laterSubmission error:&error],
                        error);
                assert(laterToken.completed &&
                       gpu_dep_word(laterBytes, 0) ==
                           UINT64_C(0x4444444444444444));
            } else {
                assert(writer == open && !writer.submitted &&
                       gpu_dep_word(ram, 32764) ==
                           UINT64_C(0x4444444444444444));
                require([cache submitWithError:&error] &&
                            [cache waitForSubmission:target.lastSubmitted
                                               error:&error],
                        error);
                assert(writer.completed && gpu_dep_word(ram, 32764) ==
                                               UINT64_C(0x7777777777777777));
            }
            require([cache discardForRestoreWithError:&error], error);
            cases++;
        }
    }
    @autoreleasepool {
        NSError *error = nil;
        ReaderPublicationCommands *target =
            [[ReaderPublicationCommands alloc] initWithDevice:device
                                                        error:&error];
        target.omitReadEvent = YES;
        IndependentReadCommands *source =
            [[IndependentReadCommands alloc] initWithDevice:device
                                                      error:&error];
        id<MTLBuffer> ram =
            [device newBufferWithLength:65536
                                options:MTLResourceStorageModeShared];
        require(target && source && ram, error);
        memset(ram.contents, 0x44, ram.length);
        NV2AMetalSurfaceCache *cache =
            [[NV2AMetalSurfaceCache alloc] initWithCommands:target
                                                       vram:ram
                                               didWriteVRAM:nil
                                                      error:&error];
        require(cache != nil, error);
        id<MTLBuffer> old = nil, laterBytes = nil;
        NV2AMetalIndependentReads *first =
            gpu_dep_read(cache, source, 32764, &old);
        require([source waitForSubmission:source.lastSubmitted error:&error],
                error);
        gpu_dep_gate(source);
        NV2AMetalIndependentReads *later =
            gpu_dep_read(cache, source, 40000, &laterBytes);
        gpu_dep_write(cache, 40000, UINT64_C(0x8888888888888888));
        require([cache submitWithError:&error] &&
                    [target waitForSubmission:target.lastSubmitted
                                        error:&error],
                error);
        NSArray *entries = [cache valueForKey:@"submissions"];
        IndependentReadReceipt *writer = reader_delayed_feedback(target);
        [entries[0] setValue:writer forKey:@"submission"];
        require([cache completeIndependentReads:first error:&error], error);
        assert(!target.publicationWaits && !writer.ready &&
               !source.gate.signaledValue &&
               ![source.lastSubmitted completedWithError:NULL] &&
               gpu_dep_word(old, 0) == UINT64_C(0x4444444444444444));
        source.gate.signaledValue = 1;
        require([source waitForSubmission:source.lastSubmitted error:&error],
                error);
        assert(gpu_dep_word(laterBytes, 0) == UINT64_C(0x8888888888888888));
        assert(![cache completeIndependentReads:later error:&error] && error &&
               writer.ready && target.publicationWaits == 1);
        cache = nil;
        require([source waitUntilIdleWithError:&error] &&
                    [target waitUntilIdleWithError:&error],
                error);
        cases++;
    }
    assert(cases == 23);
    checks += cases;
    puts("Metal reader publication:23 native reader/producer-recording "
         "damaged-reader/later-source-prefix/unrelated-head/"
         "writer-error/missing-error cases;delayed writer feedback cannot "
         "publish invalid "
         "reader bytes,required writer prefix checked,unrelated queue feedback "
         "untouched;unsubmitted writes and later surface "
         "submissions/recordings stay intact;"
         "two conflicting writers validate in order and retire without repeat waits;"
         "two readers share writer validation;"
         "confirmed writer feedback is reused for publication without a new wait;"
         "ready later feedback skips its wait and ready failure stays sticky;"
         "earlier delayed failure has priority over ready later failure;"
         "no foreign reader traversal during explicit completion;"
         "writer prefix found without scanning unrelated later writers;"
         "writer queue position wraps without changing prefix scope;"
         "two Surface submissions reuse the same reader feedback check;"
         "retirement and later completion reuse confirmed reader feedback;"
         "writer feedback arriving during a reader wait needs no writer wait;"
         "later reader failure does not poison a valid earlier reader PASS");
}
#endif
