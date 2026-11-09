/* Fixed Z16 byte blits versus preserved raw compute transfers.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DIRECT_Z16_H
#define TEST_METAL_DIRECT_Z16_H

typedef struct {
    NSUInteger scratch, uniforms;
    unsigned blits, dispatches, libraries, pipelines, tables;
} Z16TransferStats;
static unsigned z16_case;
static void z16_bytes(const char *operation, const void *actual,
                      const void *expected, NSUInteger length)
{
    const uint8_t *a = actual, *b = expected;
    for (NSUInteger i = 0; i < length; i++)
        if (a[i] != b[i]) {
            fprintf(stderr,
                    "Direct Z16 %s raw byte mismatch case%u at%lu: "
                    "got%u expected%u\n",
                    operation, z16_case, (unsigned long)i, a[i], b[i]);
            abort();
        }
}
static uint16_t z16_word(NSUInteger index, BOOL nativeSeed)
{
    return nativeSeed ? (uint16_t)(index * 4051 + 17) : (uint16_t)index;
}
static Z16TransferStats z16_transfer(NV2AMetalSurfaceTransfer *surface,
                                     id<MTLBuffer> buffer, NSUInteger offset,
                                     BOOL upload, BOOL swizzle, BOOL flip,
                                     BOOL downscale)
{
    copyScratchBytes = copyUniformBytes = 0;
    copyBlitEncoders = copyDispatchEncoders = 0;
    copyTransferBuffer = buffer;
    measureCopy = YES;
    lazy_begin(0);
    NSError *error = nil;
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
    lazy_watch = NO;
    measureCopy = NO;
    copyTransferBuffer = nil;
    Z16TransferStats stats = { copyScratchBytes,   copyUniformBytes,
                               copyBlitEncoders,   copyDispatchEncoders,
                               lazy_library_calls, lazy_compute_calls,
                               lazy_argument_calls };
    require(ok, error);
    return stats;
}
static void z16_stats(Z16TransferStats stats, BOOL direct)
{
    /* Data oracles run first: an over-admitted transform must be caught by
     * its GPU bytes, rather than only by a different dispatch count. */
    if (direct)
        assert(!stats.scratch && !stats.uniforms && stats.blits == 1 &&
               !stats.dispatches && !stats.libraries && !stats.pipelines &&
               !stats.tables);
    else
        assert(stats.uniforms == sizeof(NV2AMetalSurfaceTransferUniforms) &&
               stats.dispatches == 1);
}
static void z16_raw_copy(id<MTLTexture> texture, id<MTLBuffer> buffer,
                         NSUInteger pitch, BOOL upload)
{
    NSError *error = nil;
    require([commands addResource:texture error:&error] &&
                [commands addResource:buffer error:&error],
            error);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    MTLSize size = MTLSizeMake(texture.width, texture.height, 1);
    if (upload)
        [encoder copyFromBuffer:buffer
                   sourceOffset:0
              sourceBytesPerRow:pitch
            sourceBytesPerImage:0
                     sourceSize:size
                      toTexture:texture
               destinationSlice:0
               destinationLevel:0
              destinationOrigin:MTLOriginMake(0, 0, 0)];
    else
        [encoder copyFromTexture:texture
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:size
                            toBuffer:buffer
                   destinationOffset:0
              destinationBytesPerRow:pitch
            destinationBytesPerImage:0
                             options:MTLBlitOptionNone];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
}

static void z16_case_run(NV2AMetalSurfaceConfig config, NSUInteger offset,
                         BOOL privateBuffers, BOOL downscale, BOOL flip,
                         BOOL exactEnd)
{
    NSError *error = nil;
    lazy_begin(0);
    NV2AMetalSurfaceTransfer *candidate =
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&config
                                                   error:&error];
    lazy_watch = NO;
    unsigned initResources =
        lazy_library_calls + lazy_compute_calls + lazy_argument_calls;
    require(candidate != nil, error);
    NV2AMetalSurfaceTransfer *reference =
        [[SurfaceCopyReference alloc] initWithDevice:commands.device
                                              config:&config
                                               error:&error];
    require(reference != nil, error);
    assert(candidate.texture.pixelFormat == MTLPixelFormatDepth16Unorm &&
           reference.texture.pixelFormat == MTLPixelFormatDepth16Unorm);
    id<MTLBuffer> host =
        [commands.device newBufferWithLength:offset + candidate.sourceLength
                                     options:MTLResourceStorageModeShared];
    assert(host);
    memset(host.contents, 0xa7, host.length);
    for (unsigned y = 0; y < config.height; y++)
        for (unsigned x = 0; x < config.width; x++) {
            uint16_t code = z16_word((NSUInteger)y * config.width + x, NO);
            NSUInteger at =
                offset + (config.swizzle ?
                              2 * morton(x, y, config.width, config.height) :
                              y * config.pitch + 2 * x);
            memcpy((uint8_t *)host.contents + at, &code, 2);
        }
    NSData *immutableInput = [NSData dataWithBytes:host.contents
                                            length:host.length];
    id<MTLBuffer> source =
        privateBuffers ?
            [commands.device
                newBufferWithLength:host.length
                            options:MTLResourceStorageModePrivate] :
            host;
    NSUInteger physicalWidth = candidate.texture.width;
    NSUInteger physicalHeight = candidate.texture.height;
    NSUInteger nativePitch = (physicalWidth * 2 + 255) & ~(NSUInteger)255;
    id<MTLBuffer> native =
        [commands.device newBufferWithLength:nativePitch * physicalHeight
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> physical[2] = {
        [commands.device newBufferWithLength:native.length
                                     options:MTLResourceStorageModeShared],
        [commands.device newBufferWithLength:native.length
                                     options:MTLResourceStorageModeShared]
    };
    assert(source && native && physical[0] && physical[1]);
    memset(native.contents, 0x6d, native.length);
    for (NSUInteger y = 0; y < physicalHeight; y++)
        for (NSUInteger x = 0; x < physicalWidth; x++) {
            uint16_t code = z16_word(y * physicalWidth + x, YES);
            memcpy((uint8_t *)native.contents + y * nativePitch + x * 2, &code,
                   2);
        }
    unsigned width = downscale ? config.width : (unsigned)physicalWidth;
    unsigned height = downscale ? config.height : (unsigned)physicalHeight;
    unsigned pitch = config.pitch * (downscale ? 1 : config.scale);
    NSUInteger outputLength = offset +
                              span(width, height, pitch, 2, config.swizzle) +
                              (exactEnd ? 0 : 9);
    id<MTLBuffer> output[2] = {
        [commands.device newBufferWithLength:outputLength
                                     options:MTLResourceStorageModeShared],
        [commands.device newBufferWithLength:outputLength
                                     options:MTLResourceStorageModeShared]
    };
    id<MTLBuffer> privateOutput =
        privateBuffers ?
            [commands.device
                newBufferWithLength:outputLength
                            options:MTLResourceStorageModePrivate] :
            nil;
    assert(output[0] && output[1] && (!privateBuffers || privateOutput));
    memset(output[0].contents, 0xcd, outputLength);
    memset(output[1].contents, 0xcd, outputLength);
    NSMutableData *expected = [NSMutableData dataWithLength:outputLength];
    memset(expected.mutableBytes, 0xcd, expected.length);
    for (unsigned y = 0; y < height; y++)
        for (unsigned x = 0; x < width; x++) {
            NSUInteger px = x * (downscale ? config.scale : 1);
            NSUInteger py = y * (downscale ? config.scale : 1);
            if (flip)
                py = physicalHeight - 1 - py;
            uint16_t code = z16_word(py * physicalWidth + px, YES);
            NSUInteger at =
                offset + (config.swizzle ? 2 * morton(x, y, width, height) :
                                           y * pitch + x * 2);
            memcpy((uint8_t *)expected.mutableBytes + at, &code, 2);
        }
    require([commands beginWithError:&error], error);
    if (source != host)
        copy_producer(host, source);
    if (privateOutput)
        copy_producer(output[0], privateOutput);
    Z16TransferStats upload =
        z16_transfer(candidate, source, offset, YES, NO, NO, NO);
    require([reference encodeUploadFromBuffer:source
                                       offset:offset
                                     commands:commands
                                        error:&error],
            error);
    z16_raw_copy(candidate.texture, physical[0], nativePitch, NO);
    z16_raw_copy(reference.texture, physical[1], nativePitch, NO);
    /* Download starts from a separate known raw native image, not from either
     * upload result. An inverse pair of transfer bugs cannot cancel here. */
    z16_raw_copy(candidate.texture, native, nativePitch, YES);
    z16_raw_copy(reference.texture, native, nativePitch, YES);
    Z16TransferStats download =
        z16_transfer(candidate, privateOutput ?: output[0], offset, NO,
                     config.swizzle, flip, downscale);
    require([reference encodeDownloadToBuffer:output[1]
                                       offset:offset
                                      swizzle:config.swizzle
                                         flip:flip
                                    downscale:downscale
                                     commands:commands
                                        error:&error],
            error);
    if (privateOutput)
        copy_producer(privateOutput, output[0]);
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    for (NSUInteger y = 0; y < physicalHeight; y++)
        for (NSUInteger x = 0; x < physicalWidth; x++) {
            uint16_t code = z16_word(
                (y / config.scale) * config.width + x / config.scale, NO);
            for (unsigned side = 0; side < 2; side++)
                z16_bytes("upload physical",
                          (const uint8_t *)physical[side].contents +
                              y * nativePitch + x * 2,
                          &code, 2);
        }
    z16_bytes("upload immutable input", host.contents, immutableInput.bytes,
              host.length);
    z16_bytes("download candidate", output[0].contents, expected.bytes,
              outputLength);
    z16_bytes("download compute reference", output[1].contents, expected.bytes,
              outputLength);
    assert(!initResources);
    BOOL directUpload = !config.swizzle && config.scale == 1 && !(offset % 2) &&
                        config.pitch <= 32768;
    BOOL directDownload = !config.swizzle && !flip &&
                          (!downscale || config.scale == 1) && !(offset % 2) &&
                          pitch <= 32768;
    z16_stats(upload, directUpload);
    z16_stats(download, directDownload);
}

static void z16_format_control(BOOL floating)
{
    NSError *error = nil;
    unsigned bytes = floating ? 2 : 4;
    NV2AMetalSurfaceConfig c = { .format =
                                     floating ?
                                         NV097_SET_SURFACE_FORMAT_ZETA_Z16 :
                                         NV097_SET_SURFACE_FORMAT_ZETA_Z24S8,
                                 .width = 7,
                                 .height = 3,
                                 .pitch = 10 * bytes,
                                 .scale = 1,
                                 .floating_depth = floating };
    NV2AMetalSurfaceTransfer *surfaces[2] = {
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&c
                                                   error:&error],
        [[SurfaceCopyReference alloc] initWithDevice:commands.device
                                              config:&c
                                               error:&error]
    };
    require(surfaces[0] && surfaces[1], error);
    NSUInteger offset = 2 * bytes,
               length = offset + surfaces[0].sourceLength + 9;
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
    memset(input.contents, 0xa7, length);
    NSMutableData *expected = [NSMutableData dataWithLength:length];
    memset(expected.mutableBytes, 0xcd, length);
    for (unsigned y = 0; y < c.height; y++)
        for (unsigned x = 0; x < c.width; x++) {
            unsigned i = y * c.width + x;
            uint32_t word = floating ?
                                0x2a00 + 17 * i :
                                ((i * 4051 + 17) << 8) | ((i * 71 + 9) & 255);
            NSUInteger at = offset + y * c.pitch + x * bytes;
            memcpy((uint8_t *)input.contents + at, &word, bytes);
            memcpy((uint8_t *)expected.mutableBytes + at, &word, bytes);
        }
    memset(output[0].contents, 0xcd, length);
    memset(output[1].contents, 0xcd, length);
    require([commands beginWithError:&error] != nil, error);
    Z16TransferStats upload =
        z16_transfer(surfaces[0], input, offset, YES, NO, NO, NO);
    require([surfaces[1] encodeUploadFromBuffer:input
                                         offset:offset
                                       commands:commands
                                          error:&error],
            error);
    Z16TransferStats download =
        z16_transfer(surfaces[0], output[0], offset, NO, NO, NO, YES);
    require([surfaces[1] encodeDownloadToBuffer:output[1]
                                         offset:offset
                                        swizzle:NO
                                           flip:NO
                                      downscale:YES
                                       commands:commands
                                          error:&error],
            error);
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    z16_bytes(floating ? "F16 candidate" : "Z24 candidate", output[0].contents,
              expected.bytes, length);
    z16_bytes(floating ? "F16 compute" : "Z24 compute", output[1].contents,
              expected.bytes, length);
    z16_stats(upload, NO);
    z16_stats(download, NO);
}

static void direct_z16_tests(void)
{
    Method library =
        class_getClassMethod(NV2AMetalShaderLibrary.class,
                             @selector(sharedWithDevice:source:error:));
    Method compute = class_getInstanceMethod(NV2AMetalShaderLibrary.class,
                                             @selector(computeFunction:error:));
    Method arguments = class_getInstanceMethod(
        object_getClass(commands.device),
        @selector(newArgumentTableWithDescriptor:error:));
    assert(library && compute && arguments);
    lazy_library_original =
        (void *)method_setImplementation(library, (IMP)lazy_library);
    lazy_compute_original =
        (void *)method_setImplementation(compute, (IMP)lazy_compute);
    lazy_arguments_original =
        (void *)method_setImplementation(arguments, (IMP)lazy_arguments);
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
    z16_case = 0;
    @try {
        for (unsigned storage = 0; storage < 2; storage++)
            for (unsigned odd = 0; odd < 2; odd++)
                for (unsigned padded = 0; padded < 2; padded++) {
                    NV2AMetalSurfaceConfig c = {
                        .format = NV097_SET_SURFACE_FORMAT_ZETA_Z16,
                        .width = 256,
                        .height = 256,
                        .pitch = padded ? 516 : 512,
                        .scale = 1
                    };
                    z16_case_run(c, 2 + odd, storage, YES, NO, NO);
                    z16_case++;
                }
        for (unsigned variant = 0; variant < 8; variant++) {
            NV2AMetalSurfaceConfig c = { .format =
                                             NV097_SET_SURFACE_FORMAT_ZETA_Z16,
                                         .width = 7,
                                         .height = 3,
                                         .pitch = 20,
                                         .scale = 1 };
            BOOL downscale = YES, flip = NO, exact = NO, privateBuffers = NO;
            NSUInteger offset = 2;
            switch (variant) {
            case 0:
                offset = 6;
                break;
            case 1:
                c.height = 1;
                c.pitch = 32768;
                exact = privateBuffers = YES;
                break;
            case 2:
                c.height = 1;
                c.pitch = 32770;
                exact = YES;
                break;
            case 3:
                c.width = 8;
                c.height = 4;
                c.swizzle = YES;
                break;
            case 4:
                c.scale = 2;
                break;
            case 5:
                c.scale = 2;
                downscale = NO;
                break;
            case 6:
                flip = YES;
                break;
            case 7:
                c.scale = 4;
                downscale = NO;
                break;
            }
            z16_case_run(c, offset, privateBuffers, downscale, flip, exact);
            z16_case++;
        }
        z16_format_control(YES);
        z16_case++;
        z16_format_control(NO);
        z16_case++;
    } @finally {
        lazy_watch = measureCopy = NO;
        copyTransferBuffer = nil;
        method_setImplementation(library, (IMP)lazy_library_original);
        method_setImplementation(compute, (IMP)lazy_compute_original);
        method_setImplementation(arguments, (IMP)lazy_arguments_original);
        method_setImplementation(end, (IMP)copy_end_original);
    }
    assert(z16_case == 18);
    puts("Metal4 direct Z16:18 groups,8 exhaustive 65536-code "
         "upload/raw-native-download "
         "pairs,Shared/Private,offset/pitch/padding/exact-end/scale/flip/"
         "swizzle,"
         "F16/Z24 fallback;independent exact GPU bytes and zero direct compute "
         "resources PASS");
}

#endif
