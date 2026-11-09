/* Byte-compatible linear BGRA uploads versus the unchanged RGBA decoder.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_LINEAR_BGRA_H
#define TEST_METAL_LINEAR_BGRA_H

@interface NV2AMetalTextureUpload (LinearBGRAReference)
- (unsigned)storageForShape:(const NV2AMetalTextureShape *)shape;
@end
@interface LinearBGRAReference : NV2AMetalTextureUpload
@end
@implementation LinearBGRAReference
- (unsigned)storageForShape:(const NV2AMetalTextureShape *)s
{
    unsigned storage = [super storageForShape:s];
    return storage == NV2AMetalTextureStorageBGRA8 ||
                   storage == NV2AMetalTextureStorageBGRX8 ?
               NV2AMetalTextureStorageUnorm8 :
               storage;
}
@end

static _Thread_local BOOL lbg_scope;
static _Thread_local NSUInteger lbg_dispatches, lbg_encoders;
static void (*lbg_dispatch_original)(id, SEL, MTLSize, MTLSize);
static id (*lbg_encoder_original)(id, SEL);
static void lbg_dispatch(id self, SEL sel, MTLSize size, MTLSize group)
{
    if (lbg_scope)
        lbg_dispatches++;
    lbg_dispatch_original(self, sel, size, group);
}
static id lbg_encoder(id self, SEL sel)
{
    if (lbg_scope)
        lbg_encoders++;
    return lbg_encoder_original(self, sel);
}

static void lbg_pair(unsigned format, unsigned width, unsigned height,
                     unsigned pitch, NSUInteger offset, BOOL privateSource,
                     unsigned signedMask, BOOL direct, BOOL snapshot)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalTextureShape s = shape(format);
        s.width = width;
        s.height = height;
        s.pitch = pitch;
        s.signed_channels = signedMask;
        NSUInteger length =
            (offset + (NSUInteger)pitch * height + 3) & ~(NSUInteger)3;
        NSMutableData *seed = [NSMutableData dataWithLength:length];
        memset(seed.mutableBytes, 0xcd, length);
        for (unsigned y = 0; y < height; y++)
            for (unsigned x = 0; x < width; x++) {
                unsigned i = y * width + x;
                uint8_t bgra[] = { i, 255 - i, i * 71, i * 29 + 7 };
                memcpy((uint8_t *)seed.mutableBytes + offset + y * pitch +
                           x * 4,
                       bgra, 4);
            }
        id<MTLBuffer> out[2];
        NV2AMetalTextureUploadResult *result[2];
        NSUInteger dispatches[2], scratch[2], encoders[2];
        BOOL decoderAllocated[2];
        for (unsigned mode = 0; mode < 2; mode++) {
            NV2AMetalTextureUpload *engine =
                mode ?
                    [[LinearBGRAReference alloc] initWithDevice:commands.device
                                                          error:&error] :
                    [[NV2AMetalTextureUpload alloc]
                        initWithDevice:commands.device
                                 error:&error];
            require(engine != nil, error);
            require([commands beginWithError:&error] != nil, error);
            id<MTLBuffer> input = buffer(seed.bytes, length);
            id<MTLBuffer> source = input;
            if (privateSource) {
                source = [commands.device
                    newBufferWithLength:length
                                options:MTLResourceStorageModePrivate];
                assert(source);
                require([commands addResource:input error:&error] &&
                            [commands addResource:source error:&error],
                        error);
                id<MTL4ComputeCommandEncoder> e =
                    [commands.commandBuffer computeCommandEncoder];
                assert(e);
                [e copyFromBuffer:input
                         sourceOffset:0
                             toBuffer:source
                    destinationOffset:0
                                 size:length];
                [e endEncoding];
            }
            TextureUploadTestCommands *measured = (id)commands;
            measured.scratchBytes = 0;
            measured.measureScratch = YES;
            lbg_dispatches = lbg_encoders = 0;
            lbg_scope = YES;
            result[mode] = [engine encodeData:source
                                       offset:offset
                                      palette:nil
                                paletteOffset:0
                                paletteLength:0
                                        shape:&s
                                     commands:commands
                                        error:&error];
            lbg_scope = NO;
            measured.measureScratch = NO;
            require(result[mode] != nil, error);
            dispatches[mode] = lbg_dispatches;
            encoders[mode] = lbg_encoders;
            scratch[mode] = measured.scratchBytes;
            decoderAllocated[mode] = [engine valueForKey:@"_module"] != nil;
            out[mode] = test_metal_read_texture_decoded(
                commands, result[mode].texture, 0, 0,
                result[mode].mixedSignedHalf ? (15u ^ signedMask) : 0);
            finish();
        }
        /* Actual GPU pixels precede all route/format/metadata assertions. */
        for (unsigned y = 0; y < height; y++)
            for (unsigned x = 0; x < width; x++) {
                const float *a = pixel(out[0], width, height, x, y, 0);
                const float *b = pixel(out[1], width, height, x, y, 0);
                assert(!memcmp(a, b, 16));
                unsigned i = y * width + x;
                const uint8_t rgba[] = { i * 71, 255 - i, i, i * 29 + 7 };
                for (unsigned k = 0; k < 4; k++) {
                    float expected =
                        format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8 &&
                                k == 3 ?
                            1.f :
                        signedMask & (1u << k) ? (int8_t)rgba[k] / 128.f :
                                                 rgba[k] / 255.f;
                    check(a[k], expected);
                }
            }
        for (unsigned mode = 0; mode < 2; mode++) {
            BOOL copied = !mode && direct;
            NSUInteger row = ((NSUInteger)width * (signedMask ? 8 : 4) + 255) &
                             ~(NSUInteger)255;
            assert(dispatches[mode] == (copied ? 0 : 1));
            assert(encoders[mode] == 1);
            assert(decoderAllocated[mode] == !copied);
            assert(scratch[mode] ==
                   (privateSource ? length : 0) + (copied ? 0 : row * height));
            assert(!*(uint32_t *)result[mode].faults.contents);
            assert(result[mode].sourceLength == (NSUInteger)pitch * height);
            assert(result[mode].texture.pixelFormat ==
                   (signedMask ? MTLPixelFormatRGBA16Float :
                    mode       ? MTLPixelFormatRGBA8Unorm :
                                 MTLPixelFormatBGRA8Unorm));
        }
        if (snapshot) {
            NSData *wire = nv2a_metal_texture_snapshot(result[0].texture,
                                                       commands, &error);
            require(wire != nil, error);
            require(nv2a_metal_texture_snapshot_validate(wire, &error), error);
            id<MTLTexture> restored =
                nv2a_metal_texture_restore(wire, commands, &error);
            require(restored != nil, error);
            NSData *again =
                nv2a_metal_texture_snapshot(restored, commands, &error);
            require(again != nil, error);
            assert([wire isEqualToData:again]);
            require([commands beginWithError:&error] != nil, error);
            id<MTLBuffer> read = read_texture(restored, 0, 0);
            finish();
            for (unsigned y = 0; y < height; y++)
                for (unsigned x = 0; x < width; x++)
                    assert(!memcmp(pixel(read, width, height, x, y, 0),
                                   pixel(out[1], width, height, x, y, 0), 16));
        }
    }
}

static void lbg_rejections(void)
{
    NSError *error = nil;
    id<MTLBuffer> source = buffer((uint8_t[64]){ 0 }, 64);
    const unsigned formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5
    };
    for (unsigned f = 0; f < 3; f++)
        for (unsigned bad = 0; bad < 3; bad++) {
            NV2AMetalTextureShape s = shape(formats[f]);
            s.pitch = bad == 0 ? 9 : 16;
            NSUInteger offset = bad == 1 ? NSUIntegerMax : bad == 2 ? 48 : 0;
            NV2AMetalTextureUpload *engine =
                [[NV2AMetalTextureUpload alloc] initWithDevice:commands.device
                                                         error:&error];
            require(engine != nil, error);
            require([commands beginWithError:&error] != nil, error);
            error = nil;
            lbg_dispatches = lbg_encoders = 0;
            lbg_scope = YES;
            NV2AMetalTextureUploadResult *r = [engine encodeData:source
                                                          offset:offset
                                                         palette:nil
                                                   paletteOffset:0
                                                   paletteLength:0
                                                           shape:&s
                                                        commands:commands
                                                           error:&error];
            lbg_scope = NO;
            assert(!r && error && !lbg_dispatches && !lbg_encoders);
            assert(![engine valueForKey:@"_module"]);
            [commands cancel];
        }
}

static void linear_bgra_tests(void)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    Method dispatch = class_getInstanceMethod(
        object_getClass(e), @selector(dispatchThreads:threadsPerThreadgroup:));
    Method encoder =
        class_getInstanceMethod(object_getClass(commands.commandBuffer),
                                @selector(computeCommandEncoder));
    assert(dispatch && encoder);
    [e endEncoding];
    finish();
    lbg_dispatch_original = (void *)method_getImplementation(dispatch);
    lbg_encoder_original = (void *)method_getImplementation(encoder);
    method_setImplementation(dispatch, (IMP)lbg_dispatch);
    method_setImplementation(encoder, (IMP)lbg_encoder);
    @try {
        const struct {
            unsigned w, h, pitch, offset;
            BOOL direct;
        } cases[] = { { 256, 1, 1024, 4, YES }, { 3, 5, 64, 4, YES },
                      { 1, 1, 4, 0, YES },      { 7, 3, 32, 1, NO },
                      { 7, 3, 32, 3, NO },      { 1, 2, 65540, 4, NO },
                      { 1, 2, 65536, 4, YES },  { 16384, 1, 65536, 4, YES } };
        const unsigned formats[] = {
            NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8,
            NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8
        };
        for (unsigned f = 0; f < 2; f++)
            for (unsigned c = 0; c < sizeof(cases) / sizeof(*cases); c++)
                for (unsigned p = 0; p < 2; p++)
                    lbg_pair(formats[f], cases[c].w, cases[c].h, cases[c].pitch,
                             cases[c].offset, p, 0, cases[c].direct,
                             c < 6 && !p);
        lbg_pair(formats[0], 256, 1, 1024, 0, NO, 1, NO, NO);
        lbg_pair(formats[0], 256, 1, 1024, 1, YES, 15, NO, NO);
        lbg_rejections();
    } @finally {
        lbg_scope = NO;
        method_setImplementation(dispatch, (IMP)lbg_dispatch_original);
        method_setImplementation(encoder, (IMP)lbg_encoder_original);
    }
    puts("Metal4 linear BGRA: 34 exact GPU decoder pairs, direct/fallback "
         "dispatch+scratch, 12 snapshot roundtrips, 9 preflight rejects PASS");
}
#endif
