/* Shared Metal4 compilation resources; no app, VM or window.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import "hw/xbox/nv2a/pgraph/metal/shader-library.h"
#import "hw/xbox/nv2a/pgraph/metal/command.h"
#import "hw/xbox/nv2a/pgraph/metal/pixel-shader.h"
#import "hw/xbox/nv2a/pgraph/metal/surface-transfer.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static const char source_a[] =
    "#include <metal_stdlib>\nusing namespace metal;\nkernel void a(device "
    "uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) {o[i]=i;}\n";
static const char source_b[] =
    "#include <metal_stdlib>\nusing namespace metal;\nkernel void b(device "
    "uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) {o[i]=i+1;}\n";
static const char source_c[] =
    "#include <metal_stdlib>\nusing namespace metal;\nkernel void fill(device "
    "uint *o [[buffer(0)]], constant uint &seed [[buffer(1)]], uint i "
    "[[thread_position_in_grid]]) {o[i]=seed^(i*17u);}\n";
static const char source_bad[] = "not a valid Metal shader";
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Shared library: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static id<MTLBuffer> encode(NV2AMetalCommands *commands,
                            NV2AMetalShaderLibrary *module, uint32_t seed)
{
    NSError *error = nil;
    id<MTLComputePipelineState> pipeline = [module computeFunction:@"fill"
                                                             error:&error];
    require(pipeline != nil, error);
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:64 * 4
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:&seed
                                     length:4
                                    options:MTLResourceStorageModeShared];
    MTL4ArgumentTableDescriptor *descriptor = [MTL4ArgumentTableDescriptor new];
    descriptor.maxBufferBindCount = 2;
    descriptor.initializeBindings = YES;
    id<MTL4ArgumentTable> arguments =
        [commands.device newArgumentTableWithDescriptor:descriptor
                                                  error:&error];
    require(output && input && arguments, error);
    require([commands beginWithError:&error] != nil, error);
    require([commands addResource:output error:&error] &&
                [commands addResource:input error:&error] &&
                [commands keepAlive:arguments error:&error] &&
                [commands keepAlive:module error:&error],
            error);
    [arguments setAddress:output.gpuAddress atIndex:0];
    [arguments setAddress:input.gpuAddress atIndex:1];
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder setArgumentTable:arguments];
    [encoder setComputePipelineState:pipeline];
    [encoder dispatchThreads:MTLSizeMake(64, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
    [encoder barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return output;
}
static void verify(id<MTLBuffer> output, uint32_t seed)
{
    const uint32_t *words = output.contents;
    for (unsigned i = 0; i < 64; i++)
        assert(words[i] == (seed ^ (i * 17u)));
}
static void library_contract(id<MTLDevice> device)
{
    __weak id expiredContext = nil;
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalShaderLibrary *a =
            [NV2AMetalShaderLibrary sharedWithDevice:device
                                              source:source_a
                                               error:&error];
        NV2AMetalShaderLibrary *b =
            [NV2AMetalShaderLibrary sharedWithDevice:device
                                              source:source_b
                                               error:&error];
        require(a && b, error);
        assert(a != b && a.library != b.library && a.compiler == b.compiler);
        id context = [a valueForKey:@"context"];
        expiredContext = context;
        assert([[context valueForKey:@"libraryBuildCount"]
                   unsignedIntegerValue] == 2);
        NV2AMetalShaderLibrary *__strong modules[24] = { nil };
        id<MTLComputePipelineState> __strong pipelines[24] = { nil };
        NV2AMetalShaderLibrary *__strong *moduleSlots = modules;
        id<MTLComputePipelineState> __strong *pipelineSlots = pipelines;
        dispatch_apply(
            24, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
            ^(size_t i) {
              @autoreleasepool {
                  NSError *failure = nil;
                  moduleSlots[i] =
                      [NV2AMetalShaderLibrary sharedWithDevice:device
                                                        source:source_c
                                                         error:&failure];
                  require(moduleSlots[i] != nil, failure);
                  pipelineSlots[i] = [moduleSlots[i] computeFunction:@"fill"
                                                               error:&failure];
                  require(pipelineSlots[i] != nil, failure);
              }
            });
        for (unsigned i = 0; i < 24; i++) {
            assert(modules[i] == modules[0] && pipelines[i] == pipelines[0]);
            assert(modules[i].compiler == a.compiler);
        }
        assert([[context valueForKey:@"libraryBuildCount"]
                   unsignedIntegerValue] == 3);
        assert([[modules[0] valueForKey:@"computeBuildCount"]
                   unsignedIntegerValue] == 1);
        dispatch_apply(
            8, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
            ^(size_t i) {
              @autoreleasepool {
                  NSError *failure = nil;
                  NV2AMetalCommands *commands =
                      [[NV2AMetalCommands alloc] initWithDevice:device
                                                          error:&failure];
                  require(commands != nil, failure);
                  uint32_t seed = 0x12340000u + (uint32_t)i;
                  id<MTLBuffer> output = encode(commands, moduleSlots[i], seed);
                  require([commands submitWithError:&failure] &&
                              [commands waitUntilIdleWithError:&failure],
                          failure);
                  verify(output, seed);
              }
            });
        for (unsigned retry = 0; retry < 2; retry++) {
            error = nil;
            assert(![NV2AMetalShaderLibrary sharedWithDevice:device
                                                      source:source_bad
                                                       error:&error] &&
                   error);
            error = nil;
            assert(![modules[0] computeFunction:@"absent_function"
                                          error:&error] &&
                   error);
        }
        assert([[context valueForKey:@"libraryBuildCount"]
                   unsignedIntegerValue] == 5);
        assert([[modules[0] valueForKey:@"computeBuildCount"]
                   unsignedIntegerValue] == 1);
        error = nil;
        NSMutableString *name = [@"fill" mutableCopy];
        assert([modules[0] computeFunction:name error:&error] == pipelines[0] &&
               !error);
        [name appendString:@"_changed"];
        assert([modules[0] computeFunction:@"fill"
                                     error:&error] == pipelines[0]);
        __weak NV2AMetalShaderLibrary *expired = modules[0];
        for (unsigned i = 0; i < 24; i++) {
            modules[i] = nil;
            pipelines[i] = nil;
        }
        /* Drain observations of weak entries before testing ownership. */
        @autoreleasepool {
            assert(!expired);
        }
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        require(commands != nil, error);
        id<MTLBuffer> output;
        @autoreleasepool {
            NV2AMetalShaderLibrary *c =
                [NV2AMetalShaderLibrary sharedWithDevice:device
                                                  source:source_c
                                                   error:&error];
            require(c != nil, error);
            expired = c;
            output = encode(commands, c, 0x88776655u);
        }
        @autoreleasepool {
            assert(expired);
        }
        require([commands submitWithError:&error] &&
                    [commands waitUntilIdleWithError:&error],
                error);
        verify(output, 0x88776655u);
        @autoreleasepool {
            assert(!expired);
        }
        assert([[context valueForKey:@"libraryBuildCount"]
                   unsignedIntegerValue] == 6);
        /* Failed source/function requests do not poison successful lookups. */
        assert([NV2AMetalShaderLibrary sharedWithDevice:device
                                                 source:source_a
                                                  error:&error] == a);
    }
    assert(!expiredContext);
    puts("Shared Metal4 library:24 concurrent cold requests yield one "
         "module/pipeline;three libraries share one compiler;8 independent "
         "queues/512 exact words,failed source/function retries,mutable key "
         "isolation,weak eviction/recreation and recording/completion "
         "lifetime/64 words PASS");
}
static double seconds(void)
{
    struct timespec t;
    assert(!clock_gettime(CLOCK_MONOTONIC, &t));
    return t.tv_sec + t.tv_nsec * 1e-9;
}
static int order_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static id instance(id<MTLDevice> device, BOOL surface, unsigned variant,
                   NSError **error)
{
    if (surface) {
        NV2AMetalSurfaceConfig config = { .format = 8,
                                          .width = 8,
                                          .height = 8,
                                          .pitch = 32,
                                          .scale = 1,
                                          .color = YES };
        return [[NV2AMetalSurfaceTransfer alloc] initWithDevice:device
                                                         config:&config
                                                          error:error];
    }
    return [[NV2AMetalPixelShader alloc]
        initWithDevice:device
           colorFormat:variant & 1 ? MTLPixelFormatRGBA8Unorm :
                                     MTLPixelFormatBGRA8Unorm
           depthFormat:MTLPixelFormatInvalid
           sampleCount:1
                 error:error];
}
static void surface_compute_use(NV2AMetalSurfaceTransfer *surface,
                                NV2AMetalCommands *commands,
                                id<MTLBuffer> input, id<MTLBuffer> output)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    require([surface encodeUploadFromBuffer:input
                                     offset:0
                                   commands:commands
                                      error:&error],
            error);
    assert(![surface valueForKey:@"sharedLibrary"]);
    require([surface encodeDownloadToBuffer:output
                                     offset:0
                                    swizzle:NO
                                       flip:YES
                                  downscale:YES
                                   commands:commands
                                      error:&error],
            error);
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    for (unsigned y = 0; y < 8; y++)
        assert(!memcmp((const uint8_t *)output.contents + y * 32,
                       (const uint8_t *)input.contents + (7 - y) * 32, 32));
    assert(![surface valueForKey:@"upload"] &&
           [surface valueForKey:@"download"] &&
           [surface valueForKey:@"arguments"]);
}
static void constructor_benchmark(id<MTLDevice> device)
{
    for (unsigned surface = 0; surface < 2; surface++) {
        double cold[7], warm[112];
        unsigned index = 0;
        for (unsigned trial = 0; trial < 9; trial++) {
            @autoreleasepool {
                NSError *error = nil;
                double start = seconds();
                id anchor = instance(device, surface, 0, &error);
                double elapsed = (seconds() - start) * 1000;
                require(anchor != nil, error);
                if (trial >= 2)
                    cold[trial - 2] = elapsed;
                NV2AMetalCommands *commands = nil;
                id<MTLBuffer> input = nil, output = nil;
                if (surface) {
                    assert(![anchor valueForKey:@"sharedLibrary"] &&
                           ![anchor valueForKey:@"arguments"]);
                    commands =
                        [[NV2AMetalCommands alloc] initWithDevice:device
                                                            error:&error];
                    require(commands != nil, error);
                    input = [device
                        newBufferWithLength:256
                                    options:MTLResourceStorageModeShared];
                    output = [device
                        newBufferWithLength:256
                                    options:MTLResourceStorageModeShared];
                    assert(input && output);
                    for (unsigned i = 0; i < 256; i++)
                        ((uint8_t *)input.contents)[i] = i * 37 + i / 32 * 13;
                    surface_compute_use(anchor, commands, input, output);
                }
                NV2AMetalShaderLibrary *module =
                    [anchor valueForKey:@"sharedLibrary"];
                id context = [module valueForKey:@"context"];
                assert([[context valueForKey:@"libraryBuildCount"]
                           unsignedIntegerValue] == 1);
                for (unsigned i = 0; i < 16; i++) {
                    @autoreleasepool {
                        start = seconds();
                        id next = instance(device, surface, i, &error);
                        elapsed = (seconds() - start) * 1000;
                        require(next != nil, error);
                        if (trial >= 2)
                            warm[index++] = elapsed;
                        if (surface) {
                            assert(![next valueForKey:@"sharedLibrary"] &&
                                   ![next valueForKey:@"arguments"]);
                            surface_compute_use(next, commands, input, output);
                        }
                        assert([next valueForKey:@"sharedLibrary"] == module);
                        assert([next valueForKey:@"arguments"] !=
                               [anchor valueForKey:@"arguments"]);
                        if (surface) {
                            assert([next texture] != [anchor texture]);
                            assert([next valueForKey:@"upload"] ==
                                   [anchor valueForKey:@"upload"]);
                            assert([next valueForKey:@"download"] ==
                                   [anchor valueForKey:@"download"]);
                        }
                    }
                }
                assert([[context valueForKey:@"libraryBuildCount"]
                           unsignedIntegerValue] == 1);
                assert([[module valueForKey:@"computeBuildCount"]
                           unsignedIntegerValue] == (surface ? 1 : 0));
            }
        }
        assert(index == 112);
        qsort(cold, 7, sizeof(double), order_double);
        qsort(warm, 112, sizeof(double), order_double);
        printf(
            "Shared %s constructors:cold/warm median %.6f/%.6f ms;9 fresh "
            "ownership scopes,17 constructors each,one library request and%u "
            "compute builds per scope after actual use;private arguments/"
            "resources PASS (2 "
            "warmups,7 cold/112 warm samples;driver cache unknown)\n",
            surface ? "surface" : "pixel", cold[3], (warm[55] + warm[56]) * .5,
            surface ? 1 : 0);
    }
}
int main(void)
{
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        assert(device);
        library_contract(device);
        constructor_benchmark(device);
    }
    return 0;
}
