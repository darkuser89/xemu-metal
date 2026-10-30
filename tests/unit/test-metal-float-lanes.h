/* Float32 lane storage versus the original logical float4 contract.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_FLOAT_LANES_H
#define TEST_METAL_FLOAT_LANES_H
#include "pixel-shader-source.h"
#include "hw/xbox/nv2a/pgraph/metal/texture-upload-types.h"

typedef struct LaneCase {
    unsigned format, signedMask, storage, sourceBytes;
    BOOL linear;
} LaneCase;
static const LaneCase lane_cases[] = {
    { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y16, 0, 3, 2, NO },
    { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y16, 0, 3, 2, YES },
    { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16, 0, 4, 4, NO },
    { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16, 0, 4, 4, YES },
    { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16, 15, 4, 4, NO },
    { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16, 15, 4, 4, YES },
    { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_DEPTH_Y16_FIXED, 0, 5, 2, NO },
    { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_Y16_FIXED, 0, 5, 2, YES },
    { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_X8_Y24_FIXED, 0, 6, 4,
      YES },
    { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_X8_Y24_FLOAT, 0, 7, 4,
      YES },
    { NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_Y16_FLOAT, 0, 8, 2, YES },
};
static unsigned lane_texels, lane_snapshots, lane_sample_pairs;
static id<MTLComputePipelineState> lane_pipelines[3];
static id<MTL4ArgumentTable> lane_arguments;

static uint32_t lane_be(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 |
           (uint32_t)bytes[2] << 8 | bytes[3];
}
static uint32_t lane_bits(float value)
{
    uint32_t bits;
    memcpy(&bits, &value, 4);
    return bits;
}
static uint32_t lane_code(unsigned i, unsigned storage)
{
    const uint32_t word[] = { 0,    1,     127,   128,   4095,
                              4096, 32767, 32768, 65534, 65535 };
    const uint32_t f24[] = { 0,        1,        0xffff,   0x10000,  0x7fffff,
                             0xfeffff, 0xff0000, 0xff0001, 0xff8000, 0xffffff };
    if (storage == 7)
        return (f24[i % 10] << 8) | ((i * 31 + 17) & 255);
    if (storage == 6)
        return (((i * 7919 + 123) & 0xffffff) << 8) | (i & 255);
    if (storage == 4)
        return word[i % 10] | word[(i * 3 + 7) % 10] << 16;
    return word[i % 10];
}
/* Independent CPU oracle for the pre-existing logical decoder values. */
static void lane_expected(LaneCase c, uint32_t code, uint32_t out[4],
                          uint32_t physical[2])
{
    uint32_t zero = 0, one = 0x3f800000u, r = 0, g = 0;
    if (c.storage == 4) {
        int hi = code >> 16, lo = code & 65535;
        if (c.signedMask) {
            hi -= hi >= 32768 ? 65536 : 0;
            lo -= lo >= 32768 ? 65536 : 0;
            r = lane_bits(hi / 32768.f);
            g = lane_bits(lo / 32768.f);
        } else {
            r = lane_bits((float)(hi / 65535.0));
            g = lane_bits((float)(lo / 65535.0));
        }
        memcpy(out, (uint32_t[]){ r, g, g, one }, 16);
        physical[0] = r;
        physical[1] = g;
        return;
    }
    if (c.storage == 7)
        r = (code >> 8) << 7;
    else if (c.storage == 6)
        r = lane_bits((float)((code >> 8) / 16777215.0));
    else if (c.storage == 8) {
        uint32_t bits = code ? (code << 11) + 0x3c000000u : 0;
        float value;
        memcpy(&value, &bits, 4);
        r = lane_bits(value / 511.9375f);
    } else
        r = lane_bits((float)((code & 65535) / 65535.0));
    physical[0] = r;
    switch (c.storage) {
    case 3:
        memcpy(out, (uint32_t[]){ one, r, r, one }, 16);
        break;
    case 5:
        memcpy(out, (uint32_t[]){ r, zero, zero, zero }, 16);
        break;
    case 6:
        memcpy(out, (uint32_t[]){ r, one, zero, zero }, 16);
        break;
    case 7:
        memcpy(out, (uint32_t[]){ r, one, one, zero }, 16);
        break;
    case 8:
        memcpy(out, (uint32_t[]){ r, zero, one, zero }, 16);
        break;
    default:
        abort();
    }
}
static void lane_compare(const void *a, const void *b, NSUInteger bytes,
                         const char *label)
{
    if (!memcmp(a, b, bytes))
        return;
    const uint32_t *x = a, *y = b;
    for (NSUInteger i = 0; i < bytes / 4; i++)
        if (x[i] != y[i]) {
            fprintf(stderr, "Float lanes %s word%lu:%08x/%08x\n", label,
                    (unsigned long)i, x[i], y[i]);
            break;
        }
    abort();
}
/* Run the original float4 output mode directly from the same guest bytes.
 * This control never reads or expands the compact texture under test. */
static id<MTLTexture> lane_float_decoder(NV2AMetalTextureShape s, LaneCase c,
                                         id<MTLBuffer> source,
                                         NSUInteger offset)
{
    NSError *error = nil;
    unsigned w = s.border ? MAX(16u, 2 * s.width) : s.width;
    unsigned h = s.border ? MAX(16u, 2 * s.height) : s.height;
    unsigned d =
        s.dimension == 3 ? (s.border ? MAX(16u, 2 * s.depth) : s.depth) : 1;
    NSUInteger faceBytes = 0;
    for (unsigned level = 0; level < s.levels; level++)
        faceBytes += c.linear ? s.pitch * h :
                                MAX(1u, w >> level) * MAX(1u, h >> level) *
                                    MAX(1u, d >> level) * c.sourceBytes;
    NSUInteger faceStride =
        s.cubemap ? (faceBytes + 127) & ~(NSUInteger)127 : faceBytes;
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = s.cubemap        ? MTLTextureTypeCube :
                     s.dimension == 3 ? MTLTextureType3D :
                                        MTLTextureType2D;
    td.pixelFormat = MTLPixelFormatRGBA32Float;
    td.width = w;
    td.height = h;
    td.depth = d;
    td.mipmapLevelCount = s.levels;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> result = [commands.device newTextureWithDescriptor:td];
    uint32_t zero = 0;
    id<MTLBuffer> faults = buffer(&zero, 4);
    assert(result);
    require([commands addResource:source error:&error] &&
                [commands addResource:result error:&error] &&
                [commands addResource:faults error:&error],
            error);
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 5;
    ad.initializeBindings = YES;
    id<MTL4ArgumentTable> args =
        [commands.device newArgumentTableWithDescriptor:ad error:&error];
    require(args != nil, error);
    require([commands keepAlive:args error:&error], error);
    id<MTLComputePipelineState> pipeline = [uploader valueForKey:@"pipeline"];
    assert(pipeline);
    for (unsigned face = 0; face < (s.cubemap ? 6u : 1u); face++) {
        NSUInteger at = offset + face * faceStride;
        for (unsigned level = 0; level < s.levels; level++) {
            unsigned lw = MAX(1u, w >> level), lh = MAX(1u, h >> level),
                     ld = MAX(1u, d >> level);
            NSUInteger row = (lw * 16 + 255) & ~(NSUInteger)255;
            NV2AMetalTextureDecodeUniforms u = {
                .format = s.format,
                .linear = c.linear,
                .bytes_per_pixel = c.sourceBytes,
                .width = lw,
                .height = lh,
                .depth = ld,
                .source_width = lw,
                .source_height = lh,
                .source_depth = ld,
                .source_pitch = s.pitch,
                .output_row = (unsigned)(row / 16),
                .output_slice = (unsigned)(row * lh / 16),
                .signed_channels = s.signed_channels,
                .output_storage = NV2AMetalTextureStorageFloat32
            };
            NSUInteger uniformOffset = 0;
            id<MTLBuffer> uniform = [commands uploadBytes:&u
                                                   length:sizeof(u)
                                                   offset:&uniformOffset
                                                    error:&error];
            id<MTLBuffer> scratch = [commands.device
                newBufferWithLength:row * lh * ld
                            options:MTLResourceStorageModePrivate];
            assert(uniform && scratch);
            require([commands addResource:scratch error:&error], error);
            id<MTL4ComputeCommandEncoder> e =
                [commands.commandBuffer computeCommandEncoder];
            assert(e);
            [e barrierAfterQueueStages:MTLStageAll
                          beforeStages:MTLStageAll
                     visibilityOptions:MTL4VisibilityOptionDevice];
            [args setAddress:source.gpuAddress + at atIndex:0];
            [args setAddress:source.gpuAddress atIndex:1];
            [args setAddress:uniform.gpuAddress + uniformOffset atIndex:2];
            [args setAddress:scratch.gpuAddress atIndex:3];
            [args setAddress:faults.gpuAddress atIndex:4];
            [e setComputePipelineState:pipeline];
            [e setArgumentTable:args];
            [e dispatchThreads:MTLSizeMake(lw, lh, ld)
                threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [e barrierAfterEncoderStages:MTLStageDispatch
                     beforeEncoderStages:MTLStageBlit
                       visibilityOptions:MTL4VisibilityOptionDevice];
            [e copyFromBuffer:scratch
                       sourceOffset:0
                  sourceBytesPerRow:row
                sourceBytesPerImage:row * lh
                         sourceSize:MTLSizeMake(lw, lh, ld)
                          toTexture:result
                   destinationSlice:face
                   destinationLevel:level
                  destinationOrigin:MTLOriginMake(0, 0, 0)];
            [e barrierAfterStages:MTLStageAll
                beforeQueueStages:MTLStageAll
                visibilityOptions:MTL4VisibilityOptionDevice];
            [e endEncoding];
            at += c.linear ? s.pitch * lh :
                             (NSUInteger)lw * lh * ld * c.sourceBytes;
        }
    }
    return result;
}
static void lane_compile(void)
{
    if (lane_arguments)
        return;
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    NSMutableString *source =
        [NSMutableString stringWithUTF8String:metal_shader_source];
    for (unsigned kind = 0; kind < 3; kind++) {
        NSString *type = kind == 0 ? @"texture2d" :
                         kind == 1 ? @"texture3d" :
                                     @"texturecube";
        [source
            appendFormat:
                @"\nkernel void lane_sample%u(%@<float> t [[texture(0)]],"
                 "device uint4 *out [[buffer(0)]],constant float4 *c "
                 "[[buffer(1)]],"
                 "constant NV2AMetalSamplingUniforms &s [[buffer(2)]],"
                 "constant uint2 &grid [[buffer(3)]],uint i "
                 "[[thread_position_in_grid]]) {"
                 "if(i>=grid.x)return;uint x=i%%16,y=i/16;"
                 "float3 "
                 "p=c[0].xyz+float3(float(x)/8,float(y)/8,float((x+y)%%7)/6);"
                 "out[i]=as_type<uint4>(sample_footprint(t,p,c[1].xyz,c[2].xyz,"
                 "grid.y,%@,s));}",
                kind, type, kind == 1 ? @"true" : @"false"];
    }
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = source;
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    ld.options.mathMode = MTLMathModeSafe;
    ld.options.mathFloatingPointFunctions =
        MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld
                                                          error:&error];
    require(library != nil, error);
    for (unsigned kind = 0; kind < 3; kind++) {
        MTL4LibraryFunctionDescriptor *fn = [MTL4LibraryFunctionDescriptor new];
        fn.library = library;
        fn.name = [NSString stringWithFormat:@"lane_sample%u", kind];
        MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
        pd.computeFunctionDescriptor = fn;
        lane_pipelines[kind] =
            [compiler newComputePipelineStateWithDescriptor:pd
                                        compilerTaskOptions:nil
                                                      error:&error];
        require(lane_pipelines[kind] != nil, error);
    }
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 4;
    ad.maxTextureBindCount = 1;
    ad.initializeBindings = YES;
    lane_arguments = [commands.device newArgumentTableWithDescriptor:ad
                                                               error:&error];
    require(lane_arguments != nil, error);
}
static id<MTLBuffer> lane_sample(id<MTLTexture> texture,
                                 NV2AMetalSamplingUniforms sampling,
                                 unsigned profile, unsigned face)
{
    lane_compile();
    NSError *error = nil;
    id<MTLBuffer> result =
        [commands.device newBufferWithLength:256 * 16
                                     options:MTLResourceStorageModeShared];
    assert(result);
    const float coordinates[12] = {
        -.25f, -.125f, 0, 0,     (float[]){ .001f, .08f, .25f, 2 }[profile],
        .001f, .01f,   0, .001f, (float[]){ .001f, .04f, .125f, .02f }[profile],
        .02f,  0
    };
    const uint32_t grid[] = { 256, face };
    NSUInteger offsets[3];
    id<MTLBuffer> c = [commands uploadBytes:coordinates
                                     length:sizeof(coordinates)
                                     offset:offsets
                                      error:&error];
    id<MTLBuffer> s = [commands uploadBytes:&sampling
                                     length:sizeof(sampling)
                                     offset:offsets + 1
                                      error:&error];
    id<MTLBuffer> g = [commands uploadBytes:grid
                                     length:sizeof(grid)
                                     offset:offsets + 2
                                      error:&error];
    require(c && s && g, error);
    require([commands addResource:result error:&error] &&
                [commands addResource:texture error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageDispatch
             visibilityOptions:MTL4VisibilityOptionDevice];
    unsigned kind = texture.textureType == MTLTextureType3D   ? 1 :
                    texture.textureType == MTLTextureTypeCube ? 2 :
                                                                0;
    [lane_arguments setAddress:result.gpuAddress atIndex:0];
    [lane_arguments setAddress:c.gpuAddress + offsets[0] atIndex:1];
    [lane_arguments setAddress:s.gpuAddress + offsets[1] atIndex:2];
    [lane_arguments setAddress:g.gpuAddress + offsets[2] atIndex:3];
    [lane_arguments setTexture:texture.gpuResourceID atIndex:0];
    [e setComputePipelineState:lane_pipelines[kind]];
    [e setArgumentTable:lane_arguments];
    [e dispatchThreads:MTLSizeMake(256, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
    [e barrierAfterStages:MTLStageDispatch
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return result;
}
static void lane_filters(id<MTLTexture> texture, id<MTLTexture> restored,
                         id<MTLTexture> reference)
{
    NSError *error = nil;
    for (unsigned profile = 0; profile < 4; profile++)
        for (unsigned min = 0; min < 2; min++)
            for (unsigned mag = 0; mag < 2; mag++)
                for (unsigned mip = 0; mip < 3; mip++) {
                    NV2AMetalSamplingUniforms s = {
                        .enabled = 1,
                        .address = { 1, 2, 3 },
                        .min_linear = min,
                        .mag_linear = mag,
                        .mip_filter = mip,
                        .anisotropy = 1u << profile,
                        .lod_bias = (profile & 1) ? -.75f : .5f,
                        .border_color = { .25f, -.125f, 2, .75f }
                    };
                    if (profile == 3)
                        s.address[0] = s.address[1] = s.address[2] = 4;
                    unsigned faces =
                        texture.textureType == MTLTextureTypeCube ? 6 : 1;
                    for (unsigned face = 0; face < faces; face++) {
                        require([commands beginWithError:&error] != nil, error);
                        id<MTLBuffer> a =
                            lane_sample((profile & 1) ? restored : texture, s,
                                        profile, face);
                        id<MTLBuffer> b =
                            lane_sample(reference, s, profile, face);
                        finish();
                        lane_compare(a.contents, b.contents, a.length,
                                     "filter");
                        lane_sample_pairs++;
                    }
                }
}
static id<MTLBuffer> lane_private_source(NSData *bytes)
{
    NSError *error = nil;
    id<MTLBuffer> staging = buffer(bytes.bytes, bytes.length);
    id<MTLBuffer> result =
        [commands.device newBufferWithLength:bytes.length
                                     options:MTLResourceStorageModePrivate];
    assert(result);
    require([commands addResource:staging error:&error] &&
                [commands addResource:result error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:staging
             sourceOffset:0
                 toBuffer:result
        destinationOffset:0
                     size:bytes.length];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return result;
}
static void lane_layouts(void)
{
    NSError *error = nil;
    NV2AMetalTextureSampler *sampler =
        [[NV2AMetalTextureSampler alloc] initWithDevice:commands.device
                                                  error:&error];
    require(sampler != nil, error);
    const unsigned formats[] = { 0, 2, 4, 6 };
    for (unsigned f = 0; f < 4; f++)
        for (unsigned layout = 0; layout < 6; layout++) {
            @autoreleasepool {
                LaneCase c = lane_cases[formats[f]];
                NV2AMetalTextureShape s = shape(c.format);
                s.dimension = layout % 3 == 1 ? 3 : 2;
                s.cubemap = layout % 3 == 2;
                s.border = layout >= 3;
                s.width = 8;
                s.height = s.cubemap ? 8 : 4;
                s.depth = s.dimension == 3 ? 2 : 1;
                s.levels = 4;
                s.max_level = 3;
                s.signed_channels = c.signedMask;
                unsigned w = s.border ? 16 : s.width,
                         h = s.border ? 16 : s.height;
                unsigned d = s.dimension == 3 ? (s.border ? 16 : s.depth) : 1;
                unsigned faces = s.cubemap ? 6 : 1;
                NSUInteger faceBytes = 0;
                for (unsigned l = 0; l < 4; l++)
                    faceBytes += MAX(1u, w >> l) * MAX(1u, h >> l) *
                                 MAX(1u, d >> l) * c.sourceBytes;
                NSUInteger stride = s.cubemap ?
                                        (faceBytes + 127) & ~(NSUInteger)127 :
                                        faceBytes;
                NSMutableData *bytes =
                    [NSMutableData dataWithLength:3 + faces * stride + 16];
                uint8_t *raw = bytes.mutableBytes;
                for (unsigned face = 0; face < faces; face++) {
                    NSUInteger base = 3 + face * stride;
                    for (unsigned l = 0; l < 4; l++) {
                        unsigned lw = MAX(1u, w >> l), lh = MAX(1u, h >> l),
                                 ld = MAX(1u, d >> l);
                        for (unsigned z = 0; z < ld; z++)
                            for (unsigned y = 0; y < lh; y++)
                                for (unsigned x = 0; x < lw; x++) {
                                    unsigned i = face * 31 + l * 17 +
                                                 (z * lh + y) * lw + x;
                                    uint32_t code = lane_code(i, c.storage);
                                    NSUInteger at =
                                        base + morton(x, y, z, lw, lh, ld) *
                                                   c.sourceBytes;
                                    for (unsigned k = 0; k < c.sourceBytes; k++)
                                        raw[at + k] = code >> (8 * k);
                                }
                        base += (NSUInteger)lw * lh * ld * c.sourceBytes;
                    }
                }
                require([commands beginWithError:&error] != nil, error);
                id<MTLBuffer> source = lane_private_source(bytes);
                NV2AMetalTextureUploadResult *r = upload(s, source, 3, nil, 0);
                id<MTLTexture> reference = lane_float_decoder(s, c, source, 3);
                assert(r.sourceLength == faces * stride &&
                       r.texture.width == w && r.texture.height == h &&
                       r.texture.depth == d);
                NSMutableArray *decoded = [NSMutableArray new],
                               *old = [NSMutableArray new];
                for (unsigned face = 0; face < faces; face++)
                    for (unsigned l = 0; l < 4; l++) {
                        [decoded addObject:read_texture(r.texture, l, face)];
                        [old addObject:read_texture(reference, l, face)];
                    }
                finish();
                NSData *snapshot =
                    nv2a_metal_texture_snapshot(r.texture, commands, &error);
                require(snapshot != nil, error);
                NSUInteger packed = 40;
                for (unsigned face = 0; face < faces; face++)
                    for (unsigned l = 0; l < 4; l++) {
                        unsigned lw = MAX(1u, w >> l), lh = MAX(1u, h >> l),
                                 ld = MAX(1u, d >> l);
                        for (unsigned z = 0; z < ld; z++)
                            for (unsigned y = 0; y < lh; y++)
                                for (unsigned x = 0; x < lw; x++) {
                                    uint32_t expected[4], physical[2] = { 0 };
                                    lane_expected(
                                        c,
                                        lane_code(face * 31 + l * 17 +
                                                      (z * lh + y) * lw + x,
                                                  c.storage),
                                        expected, physical);
                                    lane_compare(pixel(decoded[face * 4 + l],
                                                       lw, lh, x, y, z),
                                                 expected, 16, "layout CPU");
                                    lane_compare(pixel(decoded[face * 4 + l],
                                                       lw, lh, x, y, z),
                                                 pixel(old[face * 4 + l], lw,
                                                       lh, x, y, z),
                                                 16, "legacy decoder");
                                    for (unsigned k = 0;
                                         k < (c.storage == 4 ? 2u : 1u); k++) {
                                        assert(lane_be((const uint8_t *)
                                                           snapshot.bytes +
                                                       packed) == physical[k]);
                                        packed += 4;
                                    }
                                    lane_texels++;
                                }
                    }
                assert(packed == snapshot.length);
                id<MTLTexture> restored =
                    nv2a_metal_texture_restore(snapshot, commands, &error);
                require(restored != nil, error);
                NSData *again =
                    nv2a_metal_texture_snapshot(restored, commands, &error);
                require(again != nil, error);
                assert([snapshot isEqual:again]);
                lane_snapshots++;
                lane_filters(r.texture, restored, reference);
                NV2AMetalSamplerConfig config = { .filter = 6u << 16 | 2u << 24,
                                                  .address =
                                                      1 | 2 << 8 | 3 << 16,
                                                  .anisotropy = 4,
                                                  .min_level = 1,
                                                  .max_level = 3,
                                                  .bordered = s.border,
                                                  .signed_channels =
                                                      c.signedMask,
                                                  .hilo16 = c.storage == 4 };
                NV2AMetalTextureBinding *view =
                    [sampler bindingForTexture:r.texture
                                        config:&config
                                         error:&error];
                NV2AMetalTextureBinding *oldView =
                    [sampler bindingForTexture:reference
                                        config:&config
                                         error:&error];
                require(view && oldView, error);
                assert(view.texture.mipmapLevelCount == 3 &&
                       view.texture.width == MAX(1u, w >> 1));
                NSData *viewBytes =
                    nv2a_metal_texture_snapshot(view.texture, commands, &error);
                require(viewBytes != nil, error);
                id<MTLTexture> viewRestore =
                    nv2a_metal_texture_restore(viewBytes, commands, &error);
                require(viewRestore != nil, error);
                NV2AMetalSamplingUniforms restoredSampling = view.sampling;
                require([sampler bindingForSnapshotTexture:viewRestore
                                                  sampling:&restoredSampling
                                                     error:&error] != nil,
                        error);
                again =
                    nv2a_metal_texture_snapshot(viewRestore, commands, &error);
                require(again != nil, error);
                assert([viewBytes isEqual:again]);
                lane_snapshots++;
                lane_filters(view.texture, viewRestore, oldView.texture);
            }
        }
}
static void lane_memory(void)
{
    NSError *error = nil;
    for (unsigned f = 0; f < 2; f++) {
        LaneCase c = lane_cases[f ? 2 : 0];
        NV2AMetalTextureShape s = shape(c.format);
        s.width = s.height = 64;
        NSMutableData *bytes =
            [NSMutableData dataWithLength:64 * 64 * c.sourceBytes];
        id<MTLBuffer> source = buffer(bytes.bytes, bytes.length);
        TextureUploadTestCommands *probe =
            (TextureUploadTestCommands *)commands;
        NSUInteger before = probe.scratchBytes;
        require([commands beginWithError:&error] != nil, error);
        probe.measureScratch = YES;
        NV2AMetalTextureUploadResult *r = upload(s, source, 0, nil, 0);
        probe.measureScratch = NO;
        id<MTLTexture> reference = lane_float_decoder(s, c, source, 0);
        finish();
        NSUInteger scratch = probe.scratchBytes - before;
        assert(scratch == 64 * 64 * (f ? 8u : 4u));
        printf("Float lane memory:64x64 %s,scratch%lu versus65536 legacy bytes,"
               "Metal reported texture allocatedSize%lu/%lu compact/Float4;"
               "no driver-heap or app memory claim\n",
               f ? "RG32" : "R32", (unsigned long)scratch,
               (unsigned long)r.texture.allocatedSize,
               (unsigned long)reference.allocatedSize);
    }
}
static void float_lane_tests(void)
{
    NSError *error = nil;
    for (unsigned f = 0; f < sizeof(lane_cases) / sizeof(*lane_cases); f++) {
        LaneCase c = lane_cases[f];
        NV2AMetalTextureShape s = shape(c.format);
        s.width = 16;
        s.height = 8;
        s.pitch = s.width * c.sourceBytes + 4 * c.sourceBytes;
        s.signed_channels = c.signedMask;
        NSUInteger length =
            c.linear ? s.pitch * s.height : s.width * s.height * c.sourceBytes;
        NSMutableData *bytes = [NSMutableData dataWithLength:length + 16];
        uint8_t *raw = bytes.mutableBytes;
        for (unsigned i = 0; i < 128; i++) {
            NSUInteger at =
                3 + (c.linear ?
                         (i / 16) * s.pitch + (i % 16) * c.sourceBytes :
                         morton(i % 16, i / 16, 0, 16, 8, 1) * c.sourceBytes);
            uint32_t code = lane_code(i, c.storage);
            for (unsigned k = 0; k < c.sourceBytes; k++)
                raw[at + k] = code >> (8 * k);
        }
        id<MTLBuffer> source = buffer(bytes.bytes, bytes.length);
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalTextureUploadResult *r = upload(s, source, 3, nil, 0);
        assert(r.texture.pixelFormat == (c.storage == 4 ?
                                             MTLPixelFormatRG32Float :
                                             MTLPixelFormatR32Float));
        id<MTLBuffer> decoded = read_texture(r.texture, 0, 0);
        id<MTLTexture> reference = lane_float_decoder(s, c, source, 3);
        finish();
        assert(!*(uint32_t *)r.faults.contents &&
               !memcmp(source.contents, bytes.bytes, bytes.length));
        NSData *snapshot =
            nv2a_metal_texture_snapshot(r.texture, commands, &error);
        require(snapshot != nil, error);
        unsigned lanes = c.storage == 4 ? 2 : 1;
        assert(snapshot.length == 40 + 128 * lanes * 4 &&
               lane_be((const uint8_t *)snapshot.bytes + 4) == 2 &&
               lane_be((const uint8_t *)snapshot.bytes + 36) == c.storage);
        for (unsigned i = 0; i < 128; i++) {
            uint32_t expected[4], physical[2] = { 0 };
            lane_expected(c, lane_code(i, c.storage), expected, physical);
            lane_compare(pixel(decoded, 16, 8, i % 16, i / 16, 0), expected, 16,
                         "CPU decode");
            for (unsigned k = 0; k < lanes; k++)
                assert(lane_be((const uint8_t *)snapshot.bytes + 40 +
                               (i * lanes + k) * 4) == physical[k]);
            lane_texels++;
        }
        id<MTLTexture> restored =
            nv2a_metal_texture_restore(snapshot, commands, &error);
        require(restored != nil, error);
        NSData *again = nv2a_metal_texture_snapshot(restored, commands, &error);
        require(again != nil, error);
        assert([snapshot isEqual:again]);
        lane_snapshots++;
        lane_filters(r.texture, restored, reference);
    }
    lane_layouts();
    lane_memory();
    printf(
        "Metal4 Float lanes:%u exact CPU/BE-payload texels,%u restore/resave "
        "pairs,%u bit-exact original/restored-vs-Float4 production filter "
        "pairs PASS\n",
        lane_texels, lane_snapshots, lane_sample_pairs);
}
#endif
