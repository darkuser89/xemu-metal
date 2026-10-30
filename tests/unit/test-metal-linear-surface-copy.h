/* Byte-identical linear color copies against the preserved compute path.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_LINEAR_SURFACE_COPY_H
#define TEST_METAL_LINEAR_SURFACE_COPY_H
#include "hw/xbox/nv2a/pgraph/metal/surface-transfer-types.h"

@interface NV2AMetalSurfaceTransfer (SurfaceCopyTest)
- (BOOL)canCopyBufferAtOffset:(NSUInteger)offset
                     uniforms:(NV2AMetalSurfaceTransferUniforms)u
                       upload:(BOOL)upload;
@end
/* Test-only reference keeps the original compute/staging branches. */
@interface SurfaceCopyReference : NV2AMetalSurfaceTransfer
@end
@implementation SurfaceCopyReference
- (BOOL)canCopyBufferAtOffset:(NSUInteger)offset
                     uniforms:(NV2AMetalSurfaceTransferUniforms)u
                       upload:(BOOL)upload
{
    (void)offset;
    (void)u;
    (void)upload;
    return NO;
}
@end

static void (*copy_end_original)(id, SEL);
static unsigned copyBlitEncoders, copyDispatchEncoders;
static void copy_end(id<MTL4ComputeCommandEncoder> encoder, SEL selector)
{
    if (measureCopy) {
        MTLStages stages = encoder.stages;
        copyBlitEncoders += !!(stages & MTLStageBlit);
        copyDispatchEncoders += !!(stages & MTLStageDispatch);
    }
    copy_end_original(encoder, selector);
}

static void copy_transfer(NV2AMetalSurfaceTransfer *surface,
                          id<MTLBuffer> buffer, NSUInteger offset, BOOL upload,
                          BOOL swizzle, BOOL flip, BOOL downscale, BOOL direct)
{
    NSError *error = nil;
    copyScratchBytes = copyUniformBytes = 0;
    copyBlitEncoders = copyDispatchEncoders = 0;
    copyTransferBuffer = buffer;
    measureCopy = YES;
    BOOL ok = upload ? [surface encodeUploadFromBuffer:buffer
                                                offset:offset
                                              commands:commands
                                                 error:&error] :
                       [surface encodeDownloadToBuffer:buffer
                                                offset:offset
                                               swizzle:swizzle
                                                  flip:flip
                                             downscale:downscale
                                              commands:commands
                                                 error:&error];
    measureCopy = NO;
    copyTransferBuffer = nil;
    require(ok, error);
    if (direct) {
        if (copyScratchBytes || copyUniformBytes || copyBlitEncoders != 1 ||
            copyDispatchEncoders)
            fprintf(stderr,
                    "Copy counters format=%u upload=%d offset=%zu: "
                    "scratch=%zu uniform=%zu blit=%u dispatch=%u\n",
                    surface.config.format, upload, (size_t)offset,
                    (size_t)copyScratchBytes, (size_t)copyUniformBytes,
                    copyBlitEncoders, copyDispatchEncoders);
        assert(!copyScratchBytes && !copyUniformBytes &&
               copyBlitEncoders == 1 && !copyDispatchEncoders);
    } else {
        assert(copyUniformBytes == sizeof(NV2AMetalSurfaceTransferUniforms) &&
               copyDispatchEncoders == 1);
    }
}

static void copy_producer(id<MTLBuffer> source, id<MTLBuffer> destination)
{
    NSError *error = nil;
    require([commands addResource:source error:&error], error);
    require([commands addResource:destination error:&error], error);
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

static void linear_copy_case(unsigned format, unsigned bytes, unsigned kind,
                             unsigned *copies, unsigned *fallbacks,
                             NSUInteger *checked)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig c = {
        .format = format,
        .width = 7,
        .height = 3,
        .pitch = 10 * bytes,
        .scale = 1,
        .color = YES,
    };
    NSUInteger offset = 2 * bytes;
    switch (kind) {
    case 0:
        c.pitch = c.width * bytes;
        break;
    case 2:
        c.width = c.height = 1;
        break;
    case 3:
        c.pitch = 16384 * bytes;
        break;
    case 4:
        c.pitch = 16385 * bytes;
        break;
    case 5:
        offset = 1;
        break;
    case 6:
        c.width = 8;
        c.height = 4;
        c.swizzle = YES;
        break;
    case 7:
    case 9:
        c.scale = 2;
        break;
    }
    NV2AMetalSurfaceTransfer *surface =
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&c
                                                   error:&error];
    require(surface != nil, error);
    NV2AMetalSurfaceTransfer *reference =
        [[SurfaceCopyReference alloc] initWithDevice:commands.device
                                              config:&c
                                               error:&error];
    require(reference != nil, error);
    NSUInteger length = offset + surface.sourceLength;
    id<MTLBuffer> host =
        [commands.device newBufferWithLength:length
                                     options:MTLResourceStorageModeShared];
    assert(host);
    memset(host.contents, 0xa7, length);
    uint8_t *input = host.contents;
    for (unsigned y = 0; y < c.height; y++)
        for (unsigned x = 0; x < c.width; x++)
            for (unsigned b = 0; b < bytes; b++)
                input[offset +
                      (c.swizzle ? morton(x, y, c.width, c.height) * bytes :
                                   y * c.pitch + x * bytes) +
                      b] = pattern(x, y, b);
    id<MTLBuffer> source =
        kind == 1 ? [commands.device
                        newBufferWithLength:length
                                    options:MTLResourceStorageModePrivate] :
                    host;
    assert(source);
    BOOL downscale = kind != 9, flip = kind == 8;
    unsigned width = c.width * (downscale ? 1 : c.scale);
    unsigned height = c.height * (downscale ? 1 : c.scale);
    unsigned pitch = c.pitch * (downscale ? 1 : c.scale);
    NSUInteger outputLength =
        offset + span(width, height, pitch, bytes, c.swizzle) + 7;
    id<MTLBuffer> output[2] = {
        [commands.device newBufferWithLength:outputLength
                                     options:MTLResourceStorageModeShared],
        [commands.device newBufferWithLength:outputLength
                                     options:MTLResourceStorageModeShared]
    };
    assert(output[0] && output[1]);
    id<MTLBuffer> privateOutput =
        kind == 1 ? [commands.device
                        newBufferWithLength:outputLength
                                    options:MTLResourceStorageModePrivate] :
                    nil;
    assert(kind != 1 || privateOutput);
    NSMutableData *expected = [NSMutableData dataWithLength:outputLength];
    memset(expected.mutableBytes, 0xcd, outputLength);
    for (unsigned y = 0; y < height; y++)
        for (unsigned x = 0; x < width; x++)
            for (unsigned b = 0; b < bytes; b++) {
                unsigned px = x / (downscale ? 1 : c.scale);
                unsigned py =
                    flip ? c.height - 1 - y : y / (downscale ? 1 : c.scale);
                ((uint8_t *)expected
                     .mutableBytes)[offset +
                                    (c.swizzle ?
                                         morton(x, y, width, height) * bytes :
                                         y * pitch + x * bytes) +
                                    b] = pattern(px, py, b);
            }
    memset(output[0].contents, 0xcd, outputLength);
    memset(output[1].contents, 0xcd, outputLength);
    require([commands beginWithError:&error] != nil, error);
    if (source != host)
        copy_producer(host, source);
    if (privateOutput)
        copy_producer(output[0], privateOutput);
    BOOL uploadDirect =
        kind != 4 && kind != 6 && kind != 7 && kind != 9 && !(offset % bytes);
    copy_transfer(surface, source, offset, YES, NO, NO, NO, uploadDirect);
    uploadDirect ? (*copies)++ : (*fallbacks)++;
    require([reference encodeUploadFromBuffer:source
                                       offset:offset
                                     commands:commands
                                        error:&error],
            error);
    BOOL downloadDirect = !c.swizzle && !flip && (!downscale || c.scale == 1) &&
                          !(offset % bytes) && pitch <= 16384 * bytes;
    copy_transfer(surface, privateOutput ?: output[0], offset, NO, c.swizzle,
                  flip, downscale, downloadDirect);
    downloadDirect ? (*copies)++ : (*fallbacks)++;
    require([reference encodeDownloadToBuffer:output[1]
                                       offset:offset
                                      swizzle:c.swizzle
                                         flip:flip
                                    downscale:downscale
                                     commands:commands
                                        error:&error],
            error);
    if (privateOutput)
        copy_producer(privateOutput, output[0]);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    compare_bytes(output[0].contents, expected.bytes, outputLength);
    compare_bytes(output[1].contents, expected.bytes, outputLength);
    *checked += 2 * outputLength;
}

static void linear_copy_ownership(unsigned format, unsigned bytes)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig c = { .format = format,
                                 .width = 7,
                                 .height = 3,
                                 .pitch = 10 * bytes,
                                 .scale = 1,
                                 .color = YES };
    NV2AMetalSurfaceTransfer *surface =
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&c
                                                   error:&error];
    require(surface != nil, error);
    NSUInteger offset = 2 * bytes, length = offset + surface.sourceLength + 7;
    id<MTLBuffer> shared =
        [commands.device newBufferWithLength:length
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> newer =
        [commands.device newBufferWithLength:length
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> shortBuffer =
        [commands.device newBufferWithLength:surface.sourceLength - 1
                                     options:MTLResourceStorageModeShared];
    assert(shared && newer && shortBuffer);
    memset(shared.contents, 0x37, length);
    memset(newer.contents, 0xa9, length);
    require([commands beginWithError:&error] != nil, error);
    assert(![surface encodeUploadFromBuffer:shortBuffer
                                     offset:0
                                   commands:commands
                                      error:&error] &&
           error);
    error = nil;
    assert(![surface encodeDownloadToBuffer:shortBuffer
                                     offset:0
                                    swizzle:NO
                                       flip:NO
                                  downscale:YES
                                   commands:commands
                                      error:&error] &&
           error);
    error = nil;
    copy_transfer(surface, shared, offset, YES, NO, NO, YES, YES);
    copy_producer(newer, shared);
    copy_transfer(surface, shared, offset, NO, NO, NO, YES, YES);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    for (NSUInteger i = 0; i < length; i++) {
        NSUInteger relative = i - offset;
        BOOL pixel = i >= offset && relative / c.pitch < c.height &&
                     relative % c.pitch < c.width * bytes;
        assert(((uint8_t *)shared.contents)[i] == (pixel ? 0x37 : 0xa9));
    }
    require([commands beginWithError:&error] != nil, error);
    __weak NV2AMetalSurfaceTransfer *borrowed;
    __weak id<MTLBuffer> borrowedSource;
    memset(shared.contents, 0x5c, length);
    @autoreleasepool {
        NV2AMetalSurfaceTransfer *cancelled =
            [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                      config:&c
                                                       error:&error];
        require(cancelled != nil, error);
        id<MTLBuffer> source =
            [commands.device newBufferWithLength:length
                                         options:MTLResourceStorageModeShared];
        assert(source);
        memset(source.contents, 0x81, length);
        copy_transfer(cancelled, source, offset, YES, NO, NO, YES, YES);
        copy_transfer(cancelled, shared, offset, NO, NO, NO, YES, YES);
        borrowed = cancelled;
        borrowedSource = source;
    }
    assert(borrowed && borrowedSource);
    [commands cancel];
    assert(!borrowed && !borrowedSource);
    for (NSUInteger i = 0; i < length; i++)
        assert(((uint8_t *)shared.contents)[i] == 0x5c);
}

static void linear_copy_benchmark(unsigned format, unsigned bytes)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig c = { .format = format,
                                 .width = 640,
                                 .height = 480,
                                 .pitch = 640 * bytes,
                                 .scale = 1,
                                 .color = YES };
    NV2AMetalSurfaceTransfer *surface[2] = {
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&c
                                                   error:&error],
        [[SurfaceCopyReference alloc] initWithDevice:commands.device
                                              config:&c
                                               error:&error]
    };
    require(surface[0] && surface[1], error);
    NSUInteger length = c.pitch * c.height;
    id<MTLBuffer> input =
        [commands.device newBufferWithLength:length
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> output[2] = {
        [commands.device newBufferWithLength:length
                                     options:MTLResourceStorageModeShared],
        [commands.device newBufferWithLength:length
                                     options:MTLResourceStorageModeShared]
    };
    assert(input && output[0] && output[1]);
    for (NSUInteger i = 0; i < length; i++)
        ((uint8_t *)input.contents)[i] = (i * 37 + i / c.pitch * 13) & 255;
    for (unsigned upload = 0; upload < 2; upload++) {
        double samples[2][9] = { 0 };
        if (!upload) {
            require([commands beginWithError:&error] != nil, error);
            for (unsigned variant = 0; variant < 2; variant++)
                require([surface[variant] encodeUploadFromBuffer:input
                                                          offset:0
                                                        commands:commands
                                                           error:&error],
                        error);
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
        }
        for (unsigned iteration = 0; iteration < 11; iteration++) {
            for (unsigned order = 0; order < 2; order++) {
                unsigned variant = (iteration + order) & 1;
                require([commands beginWithError:&error] != nil, error);
                copy_transfer(surface[variant],
                              upload ? input : output[variant], 0, upload, NO,
                              NO, YES, !variant);
                downloadGPUSeconds = 0;
                require([commands submitWithError:&error], error);
                require([commands waitUntilIdleWithError:&error], error);
                assert(isfinite(downloadGPUSeconds) && downloadGPUSeconds > 0);
                if (iteration >= 2)
                    samples[variant][iteration - 2] = downloadGPUSeconds;
                if (upload) {
                    require([commands beginWithError:&error] != nil, error);
                    require([surface[variant]
                                encodeDownloadToBuffer:output[variant]
                                                offset:0
                                               swizzle:NO
                                                  flip:NO
                                             downscale:YES
                                              commands:commands
                                                 error:&error],
                            error);
                    require([commands submitWithError:&error], error);
                    require([commands waitUntilIdleWithError:&error], error);
                }
                compare_bytes(output[variant].contents, input.contents, length);
            }
            compare_bytes(output[0].contents, output[1].contents, length);
        }
        for (unsigned variant = 0; variant < 2; variant++)
            qsort(samples[variant], 9, sizeof(double), compare_double);
        printf("Metal4 linear color %s format=%u 640x480:11 exact full-image "
               "pairs;GPU median blit/original=%.6f/%.6fms;2 warmups/9 "
               "alternating samples;blit0 scratch/uniform/dispatch PASS\n",
               upload ? "upload" : "download", format, samples[0][4] * 1000,
               samples[1][4] * 1000);
    }
}

static void linear_surface_copy_tests(void)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    id<MTL4ComputeCommandEncoder> probe =
        [commands.commandBuffer computeCommandEncoder];
    assert(probe);
    Method end =
        class_getInstanceMethod(object_getClass(probe), @selector(endEncoding));
    assert(end);
    copy_end_original = (void *)method_setImplementation(end, (IMP)copy_end);
    [probe endEncoding];
    [commands cancel];
    Method feedback = class_getInstanceMethod(MTL4CommitOptions.class,
                                              @selector(addFeedbackHandler:));
    assert(feedback);
    original_feedback =
        (void *)method_setImplementation(feedback, (IMP)download_feedback);
    unsigned copies = 0, fallbacks = 0;
    NSUInteger checked = 0;
    @try {
        const unsigned formats[] = {
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8
        };
        for (unsigned f = 0; f < 10; f++) {
            unsigned bytes = f < 3 || f == 9 ? 2 : f == 8 ? 1 : 4;
            for (unsigned kind = 0; kind < 10; kind++)
                linear_copy_case(formats[f], bytes, kind, &copies, &fallbacks,
                                 &checked);
            linear_copy_ownership(formats[f], bytes);
        }
        const unsigned benchmarkFormats[] = {
            NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_B8,
            NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8
        };
        const unsigned pixelBytes[] = { 2, 2, 4, 1, 2 };
        for (unsigned f = 0; f < 5; f++)
            linear_copy_benchmark(benchmarkFormats[f], pixelBytes[f]);
    } @finally {
        measureCopy = NO;
        method_setImplementation(end, (IMP)copy_end_original);
        method_setImplementation(feedback, (IMP)original_feedback);
    }
    printf("Metal4 linear copy:10 formats/100 layouts/%u blit transfers/%u "
           "compute fallbacks/%zu exact bytes;max/over-limit pitch,odd "
           "offsets,private producer,swizzle,scale,flip,padding and exact "
           "final span PASS\n",
           copies, fallbacks, (size_t)checked);
    puts("Metal4 linear copy ownership:10 same-buffer old/new GPU handoffs,"
         "20 short-span rejects,10 cancelled transfers with retained/released "
         "owners and unchanged output;private source/destination producer-"
         "consumer readback PASS");
}
#endif
