/* Paired whole-upload GPU durations; no application or VM.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_BC_BLOCK_BENCHMARK_H
#define TEST_METAL_BC_BLOCK_BENCHMARK_H

@interface BCBlockBenchmarkTiming : NSObject {
@public
    NSUInteger registrations, callbacks;
    CFTimeInterval start, end;
    NSError *failure;
}
@end
@implementation BCBlockBenchmarkTiming
@end

static _Thread_local BOOL bcb_reference;
static _Thread_local BOOL bcb_observing;
static _Thread_local NSUInteger bcb_admissions, bcb_accepted;
static _Thread_local __unsafe_unretained BCBlockBenchmarkTiming *bcb_timing;
static BOOL (*bcb_admission_original)(id, SEL, const NV2AMetalTextureShape *);
static void (*bcb_feedback_original)(id, SEL, MTL4CommitFeedbackHandler);
static BOOL bcb_admission(id owner, SEL selector,
                          const NV2AMetalTextureShape *shape)
{
    BOOL eligible = bcb_admission_original(owner, selector, shape);
    if (bcb_observing) {
        bcb_admissions++;
        bcb_accepted += eligible && !bcb_reference;
    }
    return eligible && !bcb_reference;
}
static void bcb_feedback(id owner, SEL selector,
                         MTL4CommitFeedbackHandler handler)
{
    BCBlockBenchmarkTiming *timing = bcb_timing;
    if (!timing) {
        bcb_feedback_original(owner, selector, handler);
        return;
    }
    @synchronized(timing) {
        timing->registrations++;
    }
    bcb_feedback_original(owner, selector, ^(id<MTL4CommitFeedback> feedback) {
      @synchronized(timing) {
          timing->callbacks++;
          timing->start = feedback.GPUStartTime;
          timing->end = feedback.GPUEndTime;
          timing->failure = feedback.error;
      }
      /* Publish timing before the real Commands handler marks its receipt
       * complete. Never replace, delay, or fabricate native feedback. */
      handler(feedback);
    });
}
static double bcb_submit(void)
{
    NSError *error = nil;
    BCBlockBenchmarkTiming *timing = [BCBlockBenchmarkTiming new];
    assert(!bcb_timing);
    bcb_timing = timing;
    @try {
        require([commands submitWithError:&error], error);
    } @finally {
        bcb_timing = nil;
    }
    require([commands waitUntilIdleWithError:&error], error);
    @synchronized(timing) {
        assert(timing->registrations == 1 && timing->callbacks == 1 &&
               !timing->failure && isfinite(timing->start) &&
               isfinite(timing->end) && timing->start > 0 &&
               timing->end > timing->start);
        return timing->end - timing->start;
    }
}

static NSData *bcb_source_bytes(unsigned family, unsigned width,
                                unsigned height, unsigned depth)
{
    unsigned blockSize = family ? 16 : 8;
    NSUInteger blocks = (NSUInteger)(width / 4) * (height / 4) * depth;
    NSMutableData *data = [NSMutableData dataWithLength:blocks * blockSize];
    for (NSUInteger block = 0; block < blocks; block++) {
        unsigned phase = block & 1;
        uint8_t *p = (uint8_t *)data.mutableBytes + block * blockSize;
        uint8_t *colors = p + (family ? 8 : 0);
        if (!family && phase) {
            colors[2] = colors[3] = 255; /* BC1 black/white transparent mode. */
        } else {
            colors[1] = 0xf8; /* Red and green, with integer 2:1/1:2 colors. */
            colors[2] = 0xe0;
            colors[3] = 7;
        }
        uint32_t selectors = 0;
        for (unsigned pixel = 0; pixel < 16; pixel++)
            selectors |= ((pixel + phase) & 3) << (2 * pixel);
        for (unsigned byte = 0; byte < 4; byte++)
            colors[4 + byte] = selectors >> (8 * byte);
        if (family == 1) {
            for (unsigned pixel = 0; pixel < 16; pixel++)
                p[pixel / 2] |= ((pixel + phase) & 15) << (4 * (pixel & 1));
        } else if (family == 2) {
            p[0] = phase ? 60 : 200;
            p[1] = phase ? 200 : 60;
            uint64_t alpha = 0;
            for (unsigned pixel = 0; pixel < 16; pixel++)
                alpha |= (uint64_t)((pixel + phase) & 7) << (3 * pixel);
            for (unsigned byte = 0; byte < 6; byte++)
                p[2 + byte] = alpha >> (8 * byte);
        }
    }
    return data;
}
static id<MTLBuffer> bcb_resident_source(NSData *bytes)
{
    NSError *error = nil;
    id<MTLBuffer> staging = buffer(bytes.bytes, bytes.length);
    id<MTLBuffer> source =
        [commands.device newBufferWithLength:bytes.length
                                     options:MTLResourceStorageModePrivate];
    require(source && [commands beginWithError:&error] &&
                [commands addResource:source error:&error] &&
                [commands addResource:staging error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e copyFromBuffer:staging
             sourceOffset:0
                 toBuffer:source
        destinationOffset:0
                     size:bytes.length];
    [e endEncoding];
    finish(); /* Source residency/initialization is outside every timed commit.
               */
    return source;
}
static void bcb_expected(unsigned family, unsigned phase, unsigned pixel,
                         uint8_t expected[4])
{
    static const uint8_t rgb[4][3] = {
        { 255, 0, 0 }, { 0, 255, 0 }, { 170, 85, 0 }, { 85, 170, 0 }
    };
    static const uint8_t gray[4] = { 0, 255, 127, 0 };
    static const uint8_t alpha[2][8] = {
        { 200, 60, 180, 160, 140, 120, 100, 80 },
        { 60, 200, 88, 116, 144, 172, 0, 255 }
    };
    unsigned selector = (pixel + phase) & 3;
    for (unsigned k = 0; k < 3; k++)
        expected[k] = !family && phase ? gray[selector] : rgb[selector][k];
    expected[3] = family == 1            ? ((pixel + phase) & 15) * 17 :
                  family == 2            ? alpha[phase][(pixel + phase) & 7] :
                  phase && selector == 3 ? 0 :
                                           255;
}

/* Raw RGBA8 readback is a different, untimed commit. Compare every texel,
 * excluding unspecified row padding, to both the old decoder and hand codes. */
static NSData *bcb_readback(NSArray<NV2AMetalTextureUploadResult *> *results,
                            unsigned family, unsigned width, unsigned height,
                            unsigned depth)
{
    NSError *error = nil;
    NSMutableArray<id<MTLBuffer>> *buffers = [NSMutableArray new];
    NSUInteger row = ((NSUInteger)width * 4 + 255) & ~(NSUInteger)255;
    require([commands beginWithError:&error] != nil, error);
    for (NV2AMetalTextureUploadResult *result in results) {
        id<MTLTexture> texture = result.texture;
        assert(texture.pixelFormat == MTLPixelFormatRGBA8Unorm &&
               texture.width == width && texture.height == height &&
               texture.depth == depth &&
               !*(const uint32_t *)result.faults.contents);
        id<MTLBuffer> out =
            [commands.device newBufferWithLength:row * height * depth
                                         options:MTLResourceStorageModeShared];
        require(out && [commands addResource:out error:&error] &&
                    [commands addResource:texture error:&error],
                error);
        memset(out.contents, 0xa5, out.length);
        id<MTL4ComputeCommandEncoder> e =
            [commands.commandBuffer computeCommandEncoder];
        require(e != nil, nil);
        [e barrierAfterQueueStages:MTLStageAll
                      beforeStages:MTLStageBlit
                 visibilityOptions:MTL4VisibilityOptionDevice];
        [e copyFromTexture:texture
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(width, height, depth)
                            toBuffer:out
                   destinationOffset:0
              destinationBytesPerRow:row
            destinationBytesPerImage:row * height];
        [e endEncoding];
        [buffers addObject:out];
    }
    finish();
    NSMutableData *actual = [NSMutableData new];
    for (id<MTLBuffer> out in buffers) {
        for (unsigned z = 0; z < depth; z++) {
            for (unsigned y = 0; y < height; y++) {
                const uint8_t *line = (const uint8_t *)out.contents +
                                      ((NSUInteger)z * height + y) * row;
                for (unsigned x = 0; x < width; x++) {
                    /* The sole volume workload has two complete four-slice
                     * chunks; alternating physical blocks therefore select
                     * the template by z parity, independently of XY. */
                    unsigned phase = depth == 1 ?
                                         ((y / 4) * (width / 4) + x / 4) & 1 :
                                         z & 1;
                    uint8_t expected[4];
                    bcb_expected(family, phase, (y & 3) * 4 + (x & 3),
                                 expected);
                    assert(!memcmp(line + x * 4, expected, 4));
                }
                [actual appendBytes:line length:width * 4];
            }
        }
    }
    return actual;
}
static int bcb_compare_time(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static void bcb_pair(unsigned family, unsigned workload)
{
    static const unsigned formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT1_A1R5G5B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT23_A8R8G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT45_A8R8G8B8
    };
    unsigned width = workload == 0 ? 16 :
                     workload == 1 ? 256 :
                     workload == 2 ? 1024 :
                                     64;
    unsigned height = width, depth = workload == 3 ? 8 : 1;
    unsigned repeats = workload == 0 ? 32 : workload == 2 ? 1 : 8;
    NV2AMetalTextureShape s = shape(formats[family]);
    s.width = width;
    s.height = height;
    s.dimension = depth == 1 ? 2 : 3;
    s.depth = depth;
    NSData *seed = bcb_source_bytes(family, width, height, depth);
    id<MTLBuffer> source = bcb_resident_source(seed);
    /* Logical source + target + largest scratch payload, not driver/heap
     * allocation accounting. No workload approaches the 32 MiB batch limit. */
    NSUInteger logicalBytes =
        seed.length +
        ((NSUInteger)width * 4 + 255) / 256 * 256 * height * depth +
        (NSUInteger)repeats * width * height * depth * 4;
    assert(logicalBytes < NV2AMetalCommandBatchExtraBytes);
    double first[2] = { 0 }, samples[2][9] = { 0 };
    for (unsigned trial = 0; trial < 12; trial++) {
        @autoreleasepool {
            NSData *pixels[2];
            for (unsigned order = 0; order < 2; order++) {
                unsigned variant = (family + workload + trial + order) & 1;
                NSError *error = nil;
                NSMutableArray<NV2AMetalTextureUploadResult *> *results =
                    [NSMutableArray new];
                require([commands beginWithError:&error] != nil, error);
                bcb_reference = !variant;
                bcb_observing = YES;
                bcb_admissions = bcb_accepted = 0;
                @try {
                    for (unsigned repeat = 0; repeat < repeats; repeat++)
                        [results addObject:upload(s, source, 0, nil, 0)];
                } @finally {
                    bcb_reference = NO;
                    bcb_observing = NO;
                }
                /* Compilation/allocation happened on the CPU before commit;
                 * none of that elapsed host time is labelled GPU time. */
                double duration = bcb_submit();
                pixels[variant] =
                    bcb_readback(results, family, width, height, depth);
                assert(bcb_admissions == repeats &&
                       bcb_accepted == (variant ? repeats : 0));
                if (!trial)
                    first[variant] = duration;
                else if (trial >= 3)
                    samples[variant][trial - 3] = duration;
            }
            assert([pixels[0] isEqualToData:pixels[1]]);
        }
    }
    for (unsigned variant = 0; variant < 2; variant++)
        qsort(samples[variant], 9, sizeof(double), bcb_compare_time);
    /* Every old/new output and fault word passed before reporting times. */
    printf("BC block GPU upload family%u %ux%ux%u x%u: "
           "first workload sample old/block %.6f/%.6f ms; "
           "warm median %.6f/%.6f ms; "
           "range old[%.6f,%.6f] block[%.6f,%.6f] ms; "
           "2 warmups,9 alternating exact pairs; decode+scratch blit only, "
           "readback separate,PSOs may be warm,CPU compiler excluded\n",
           family, width, height, depth, repeats, first[0] * 1000,
           first[1] * 1000, samples[0][4] * 1000, samples[1][4] * 1000,
           samples[0][0] * 1000, samples[0][8] * 1000, samples[1][0] * 1000,
           samples[1][8] * 1000);
}
static void bc_block_benchmark(void)
{
    Method admission = class_getInstanceMethod(
        NV2AMetalTextureUpload.class,
        NSSelectorFromString(@"canDecodeBCBlocksForShape:"));
    Method feedback = class_getInstanceMethod(MTL4CommitOptions.class,
                                              @selector(addFeedbackHandler:));
    assert(admission && feedback);
    bcb_admission_original = (void *)method_getImplementation(admission);
    bcb_feedback_original = (void *)method_getImplementation(feedback);
    method_setImplementation(admission, (IMP)bcb_admission);
    method_setImplementation(feedback, (IMP)bcb_feedback);
    @try {
        for (unsigned family = 0; family < 3; family++)
            for (unsigned workload = 0; workload < 4; workload++)
                bcb_pair(family, workload);
    } @finally {
        bcb_reference = NO;
        bcb_observing = NO;
        bcb_timing = nil;
        method_setImplementation(feedback, (IMP)bcb_feedback_original);
        method_setImplementation(admission, (IMP)bcb_admission_original);
    }
}
#endif
