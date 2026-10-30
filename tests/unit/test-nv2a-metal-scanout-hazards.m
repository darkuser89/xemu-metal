/* Offscreen Metal 4 scanout/display ordering and barrier comparison.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "hw/xbox/nv2a/pgraph/metal/display.h"
#import "hw/xbox/nv2a/pgraph/metal/scanout.h"
#import <objc/runtime.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Scanout hazards: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}

/* Test-only interception: the reference uses the original All -> All
 * barriers with exactly the same production shaders, resources and draws. */
static BOOL broad;
static unsigned consumers, producers, broadConsumers;
static void (*original_consumer)(id, SEL, MTLStages, MTLStages,
                                 MTL4VisibilityOptions);
static void (*original_producer)(id, SEL, MTLStages, MTLStages,
                                 MTL4VisibilityOptions);
static void consumer(id object, SEL selector, MTLStages after, MTLStages before,
                     MTL4VisibilityOptions options)
{
    assert(after == MTLStageAll && options == MTL4VisibilityOptionDevice);
    assert(before == MTLStageFragment || before == MTLStageAll);
    consumers++;
    broadConsumers += before == MTLStageAll;
    original_consumer(object, selector, after, broad ? MTLStageAll : before,
                      options);
}
static void producer(id object, SEL selector, MTLStages after, MTLStages before,
                     MTL4VisibilityOptions options)
{
    assert(before == MTLStageAll && options == MTL4VisibilityOptionDevice);
    assert(after == MTLStageFragment || after == MTLStageAll);
    producers++;
    original_producer(object, selector, broad ? MTLStageAll : after, before,
                      options);
}
static void (*original_feedback)(id, SEL, MTL4CommitFeedbackHandler);
static double gpuSeconds;
static void feedback_handler(id object, SEL selector,
                             MTL4CommitFeedbackHandler handler)
{
    original_feedback(object, selector, ^(id<MTL4CommitFeedback> feedback) {
      gpuSeconds = feedback.GPUEndTime - feedback.GPUStartTime;
      handler(feedback);
    });
}
static int compare_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static id<MTLTexture> texture(id<MTLDevice> device, unsigned w, unsigned h)
{
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:w
                                    height:h
                                 mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
              MTLTextureUsageRenderTarget;
    id<MTLTexture> result = [device newTextureWithDescriptor:d];
    assert(result);
    return result;
}

int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        id<MTLDevice> device = commands.device;
        id<MTL4Compiler> compiler =
            [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                        error:&error];
        require(compiler != nil, error);
        MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
        ld.source =
            @"#include <metal_stdlib>\n"
             "using namespace metal;\n"
             "kernel void pattern(texture2d<float, access::write> t "
             "[[texture(0)]], constant uint &frame [[buffer(0)]], "
             "uint2 p [[thread_position_in_grid]]) {\n"
             "if (p.x >= t.get_width() || p.y >= t.get_height()) return;\n"
             "uint v = (p.x / 8 + p.y / 8 + frame) & 7;\n"
             "t.write(float4(v & 1, (v >> 1) & 1, (v >> 2) & 1, 1), p);\n"
             "}\n";
        ld.options = [MTLCompileOptions new];
        ld.options.languageVersion = MTLLanguageVersion4_0;
        id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld
                                                              error:&error];
        require(library != nil, error);
        MTL4LibraryFunctionDescriptor *fn = [MTL4LibraryFunctionDescriptor new];
        fn.library = library;
        fn.name = @"pattern";
        MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
        pd.computeFunctionDescriptor = fn;
        id<MTLComputePipelineState> pipeline =
            [compiler newComputePipelineStateWithDescriptor:pd
                                        compilerTaskOptions:nil
                                                      error:&error];
        require(pipeline != nil, error);
        MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
        ad.maxBufferBindCount = 1;
        ad.maxTextureBindCount = 1;
        id<MTL4ArgumentTable> arguments =
            [device newArgumentTableWithDescriptor:ad error:&error];
        require(arguments != nil, error);
        NV2AMetalScanout *scanout =
            [[NV2AMetalScanout alloc] initWithDevice:device
                                         pixelFormat:MTLPixelFormatRGBA8Unorm
                                               error:&error];
        NV2AMetalDisplay *display =
            [[NV2AMetalDisplay alloc] initWithDevice:device
                                         pixelFormat:MTLPixelFormatRGBA8Unorm
                                               error:&error];
        require(scanout && display, error);
        const unsigned w = 640, h = 480, frames = 16, repetitions = 11;
        const NSUInteger row = w * 4, imageBytes = row * h;
        id<MTLTexture> source = texture(device, w, h);
        id<MTLTexture> composed = texture(device, w, h);
        id<MTLTexture> target = texture(device, w, h);
        id<MTLBuffer> readback =
            [device newBufferWithLength:imageBytes * frames
                                options:MTLResourceStorageModeShared];
        assert(readback);
        NV2AMetalScanoutUniforms su = { .output_size = { w, h },
                                        .line_offset = 1 };
        NV2AMetalDisplayUniforms du = { .scale = { 1, 1 } };
        for (unsigned i = 0; i < 256; i++)
            du.palette[i] = i | i << 8 | i << 16;

        require([commands beginWithError:&error] != nil, error);
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTL4RenderCommandEncoder> probe =
            [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
        assert(probe);
        Class cls = object_getClass(probe);
        Method cm = class_getInstanceMethod(
            cls, @selector(barrierAfterQueueStages:
                                      beforeStages:visibilityOptions:));
        Method pm = class_getInstanceMethod(
            cls, @selector(barrierAfterStages:
                            beforeQueueStages:visibilityOptions:));
        Method fm = class_getInstanceMethod(MTL4CommitOptions.class,
                                            @selector(addFeedbackHandler:));
        assert(cm && pm && fm);
        /* A driver may inherit these methods from a common compute/render
         * base. Override only this concrete render class, never that base. */
        class_addMethod(cls, method_getName(cm), method_getImplementation(cm),
                        method_getTypeEncoding(cm));
        class_addMethod(cls, method_getName(pm), method_getImplementation(pm),
                        method_getTypeEncoding(pm));
        cm = class_getInstanceMethod(cls, method_getName(cm));
        pm = class_getInstanceMethod(cls, method_getName(pm));
        [probe endEncoding];
        [commands cancel];
        original_consumer = (void *)method_setImplementation(cm, (IMP)consumer);
        original_producer = (void *)method_setImplementation(pm, (IMP)producer);
        original_feedback =
            (void *)method_setImplementation(fm, (IMP)feedback_handler);
        double times[2][9];
        unsigned checked = 0;
        for (unsigned trial = 0; trial < repetitions; trial++) {
            NSData *first = nil;
            for (unsigned variant = 0; variant < 2; variant++) {
                @autoreleasepool {
                    broad = (variant ^ (trial & 1)) != 0;
                    memset(readback.contents, 0x5a, readback.length);
                    require([commands beginWithError:&error] != nil, error);
                    for (id<MTLResource> r in
                         @[ source, composed, target, readback ])
                        require([commands addResource:r error:&error], error);
                    for (unsigned frame = 0; frame < frames; frame++) {
                        unsigned seed = trial * frames + frame;
                        id<MTLBuffer> constants = [device
                            newBufferWithBytes:&seed
                                        length:sizeof(seed)
                                       options:MTLResourceStorageModeShared];
                        assert(constants);
                        require([commands addResource:constants error:&error],
                                error);
                        [arguments setAddress:constants.gpuAddress atIndex:0];
                        [arguments setTexture:source.gpuResourceID atIndex:0];
                        id<MTL4ComputeCommandEncoder> e =
                            [commands.commandBuffer computeCommandEncoder];
                        assert(e);
                        [e setComputePipelineState:pipeline];
                        [e setArgumentTable:arguments];
                        [e dispatchThreads:MTLSizeMake(w, h, 1)
                            threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                        /* No producer barrier: scanout must order this write.
                         */
                        [e endEncoding];
                        require([scanout encodeSource:source
                                              overlay:nil
                                               target:composed
                                             uniforms:&su
                                             commands:commands
                                                error:&error],
                                error);
                        BOOL screenOff = frame % 5 == 4;
                        require([display encodeWithCommands:commands
                                                     source:composed
                                                     target:target
                                                   uniforms:&du
                                                     linear:NO
                                                  screenOff:screenOff
                                                      error:&error],
                                error);
                        e = [commands.commandBuffer computeCommandEncoder];
                        assert(e);
                        /* No consumer barrier: display must publish its store.
                         */
                        [e copyFromTexture:target
                                         sourceSlice:0
                                         sourceLevel:0
                                        sourceOrigin:MTLOriginMake(0, 0, 0)
                                          sourceSize:MTLSizeMake(w, h, 1)
                                            toBuffer:readback
                                   destinationOffset:frame * imageBytes
                              destinationBytesPerRow:row
                            destinationBytesPerImage:imageBytes];
                        /* Preserve the read before the next frame overwrites.
                         */
                        [e barrierAfterStages:MTLStageBlit
                            beforeQueueStages:MTLStageFragment
                            visibilityOptions:MTL4VisibilityOptionDevice];
                        [e endEncoding];
                    }
                    require([commands submitWithError:&error], error);
                    require([commands waitUntilIdleWithError:&error], error);
                    assert(gpuSeconds > 0);
                    if (trial >= 2)
                        times[broad][trial - 2] = gpuSeconds;
                    const uint8_t *bytes = readback.contents;
                    for (unsigned f = 0; f < frames; f++)
                        for (unsigned y = 0; y < h; y++)
                            for (unsigned x = 0; x < w; x++) {
                                unsigned v =
                                    (x / 8 + y / 8 + trial * frames + f) & 7;
                                BOOL off = f % 5 == 4;
                                for (unsigned k = 0; k < 4; k++) {
                                    unsigned want = off ? 0 :
                                                    (k == 3 || ((v >> k) & 1)) ?
                                                          255 :
                                                          0;
                                    assert(bytes[f * imageBytes + y * row +
                                                 x * 4 + k] == want);
                                }
                            }
                    if (variant == 0)
                        first = [NSData dataWithBytes:bytes
                                               length:readback.length];
                    else
                        assert(memcmp(first.bytes, bytes, readback.length) ==
                               0);
                    checked += frames;
                }
            }
        }
        method_setImplementation(cm, (IMP)original_consumer);
        method_setImplementation(pm, (IMP)original_producer);
        method_setImplementation(fm, (IMP)original_feedback);
        assert(consumers == checked * 2 && producers == consumers);
        /* Clear-only attachment actions also use the fragment stage. Their
         * black output is checked per pixel above; a broad barrier no longer
         * identifies them. Count the actual production barrier masks. */
        assert(!broadConsumers);
        qsort(times[0], 9, sizeof(double), compare_double);
        qsort(times[1], 9, sizeof(double), compare_double);
        printf("Scanout barriers: %u exact 640x480 frames, %u consumers, "
               "%u producers, %u broad-stage consumers; 11 byte-identical "
               "pairs.\n",
               checked, consumers, producers, broadConsumers);
        printf("16-frame GPU median after 2 warmups/9 samples: "
               "fragment=%.6f ms broad=%.6f ms\n",
               times[0][4] * 1000, times[1][4] * 1000);
    }
    return 0;
}
