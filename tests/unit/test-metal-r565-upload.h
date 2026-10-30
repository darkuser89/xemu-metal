/* Direct native packed16 upload versus the real unaligned GPU fallback.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_R565_UPLOAD_H
#define TEST_METAL_R565_UPLOAD_H
#include <time.h>

static double r565_now(void)
{
    struct timespec t;
    assert(!clock_gettime(CLOCK_MONOTONIC, &t));
    return t.tv_sec + t.tv_nsec / 1e9;
}
static void r565_upload_benchmark(void)
{
    NSError *error = nil;
    Method feedback = class_getInstanceMethod(MTL4CommitOptions.class,
                                              @selector(addFeedbackHandler:));
    assert(feedback);
    signed8_feedback_original =
        (void *)method_setImplementation(feedback, (IMP)signed8_feedback);
    const unsigned formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A4R4G4B4
    };
    for (unsigned family = 0; family < 4; family++)
        for (unsigned workload = 0; workload < 2; workload++) {
            NV2AMetalTextureShape s = shape(formats[family]);
            s.width = workload ? 1024 : 64;
            s.height = workload ? 512 : 64;
            s.pitch = s.width * 2;
            NSUInteger length =
                ((NSUInteger)s.pitch * s.height + 7) & ~(NSUInteger)3;
            id<MTLBuffer> source[2];
            for (unsigned mode = 0; mode < 2; mode++) {
                NSMutableData *seed = [NSMutableData dataWithLength:length];
                memset(seed.mutableBytes, 0xcc, length);
                for (unsigned y = 0; y < s.height; y++)
                    for (unsigned x = 0; x < s.width; x++) {
                        unsigned value =
                            ((y * s.width + x) * 40503 + 0x1289) & 65535;
                        uint8_t *p = (uint8_t *)seed.mutableBytes + 2 + mode +
                                     y * s.pitch + x * 2;
                        p[0] = value;
                        p[1] = value >> 8;
                    }
                source[mode] = buffer(seed.bytes, seed.length);
            }
            double cpu[2][9], gpu[2][9];
            for (unsigned trial = 0; trial < 11; trial++) {
                @autoreleasepool {
                    id<MTLBuffer> out[2];
                    for (unsigned order = 0; order < 2; order++) {
                        unsigned mode = (trial + order) & 1;
                        require([commands beginWithError:&error] != nil, error);
                        TextureUploadTestCommands *measured =
                            (TextureUploadTestCommands *)commands;
                        measured.scratchBytes = 0;
                        measured.measureScratch = YES;
                        double start = r565_now();
                        NV2AMetalTextureUploadResult *r =
                            upload(s, source[mode], 2 + mode, nil, 0);
                        double elapsed = r565_now() - start;
                        measured.measureScratch = NO;
                        assert(measured.scratchBytes ==
                               (mode ?
                                    ((s.width * 2 + 255) & ~255u) * s.height :
                                    0));
                        signed8_gpu_seconds = 0;
                        finish();
                        assert(!*(uint32_t *)r.faults.contents &&
                               signed8_gpu_seconds > 0);
                        if (trial >= 2) {
                            cpu[mode][trial - 2] = elapsed;
                            gpu[mode][trial - 2] = signed8_gpu_seconds;
                        }
                        require([commands beginWithError:&error] != nil, error);
                        out[mode] = read_texture(r.texture, 0, 0);
                        finish();
                    }
                    assert(out[0].length == out[1].length);
                    assert(!memcmp(out[0].contents, out[1].contents,
                                   out[0].length));
                    for (unsigned y = 0; y < s.height; y++)
                        for (unsigned x = 0; x < s.width; x++) {
                            unsigned value =
                                ((y * s.width + x) * 40503 + 0x1289) & 65535;
                            float expected[4] = { (value >> 11) / 31.f,
                                                  ((value >> 5) & 63) / 63.f,
                                                  (value & 31) / 31.f, 1 };
                            if (family == 1 || family == 2) {
                                expected[0] = ((value >> 10) & 31) / 31.f;
                                expected[1] = ((value >> 5) & 31) / 31.f;
                                expected[3] =
                                    family == 2 ? 1 : (float)(value >> 15);
                            } else if (family == 3) {
                                expected[0] = ((value >> 8) & 15) / 15.f;
                                expected[1] = ((value >> 4) & 15) / 15.f;
                                expected[2] = (value & 15) / 15.f;
                                expected[3] = (value >> 12) / 15.f;
                            }
                            assert(!memcmp(
                                pixel(out[0], s.width, s.height, x, y, 0),
                                expected, sizeof(expected)));
                        }
                }
            }
            for (unsigned mode = 0; mode < 2; mode++) {
                qsort(cpu[mode], 9, sizeof(double), signed8_time_compare);
                qsort(gpu[mode], 9, sizeof(double), signed8_time_compare);
            }
            printf("Packed16 family%u upload %ux%u:11 exact full-image pairs,2 "
                   "warmups/9 "
                   "alternating samples;"
                   "CPU encode direct/fallback %.6f/%.6f ms;GPU upload "
                   "%.6f/%.6f ms;"
                   "scratch 0/%u bytes PASS\n",
                   family, s.width, s.height, cpu[0][4] * 1000,
                   cpu[1][4] * 1000, gpu[0][4] * 1000, gpu[1][4] * 1000,
                   ((s.width * 2 + 255) & ~255u) * s.height);
        }
    method_setImplementation(feedback, (IMP)signed8_feedback_original);
}
#endif
