/* Float-value readback for Metal texture tests, independent of guest decoding.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_TEXTURE_READBACK_H
#define TEST_METAL_TEXTURE_READBACK_H

#import "hw/xbox/nv2a/pgraph/metal/command.h"
#include <assert.h>
#include <stdio.h>

static void test_texture_require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Texture test readback: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}

static unsigned test_texture_swizzle_index(MTLTextureSwizzle swizzle)
{
    switch (swizzle) {
    case MTLTextureSwizzleRed:
        return 0;
    case MTLTextureSwizzleGreen:
        return 1;
    case MTLTextureSwizzleBlue:
        return 2;
    case MTLTextureSwizzleAlpha:
        return 3;
    case MTLTextureSwizzleZero:
        return 4;
    case MTLTextureSwizzleOne:
        return 5;
    }
    abort();
}

/* Preserve the tests' float4 row layout without interpreting RGBA bytes as
 * float bits. Float textures remain raw blits (including NaN payloads).
 * UNORM and half texels are expanded on the GPU after the raw subresource
 * blit. Half-to-float expansion is exact. This helper performs
 * no guest-layout decode, filtering, submit or wait. Compact Float32 lanes
 * are expanded as integer words according to the texture's declared swizzle,
 * preserving subnormal and NaN payload bits. */
static id<MTLBuffer>
test_metal_read_texture_decoded(NV2AMetalCommands *commands,
                                id<MTLTexture> texture, unsigned level,
                                unsigned face, unsigned unsignedHalfMask)
{
    static id<MTLDevice> pipelineDevice;
    static id<MTLComputePipelineState> pipeline;
    static id<MTL4ArgumentTable> arguments;
    NSError *error = nil;
    id<MTLDevice> device = commands.device;
    BOOL half4 = texture.pixelFormat == MTLPixelFormatRGBA16Float;
    BOOL snorm8 = texture.pixelFormat == MTLPixelFormatRGBA8Snorm;
    BOOL packed565 = texture.pixelFormat == MTLPixelFormatB5G6R5Unorm;
    BOOL packed1555 = texture.pixelFormat == MTLPixelFormatBGR5A1Unorm;
    BOOL packed4444 = texture.pixelFormat == MTLPixelFormatABGR4Unorm;
    BOOL packed16 = packed565 || packed1555 || packed4444;
    unsigned floatLanes = texture.pixelFormat == MTLPixelFormatR32Float  ? 1 :
                          texture.pixelFormat == MTLPixelFormatRG32Float ? 2 :
                                                                           0;
    BOOL compact = half4 || snorm8 || packed16 || floatLanes ||
                   texture.pixelFormat == MTLPixelFormatRGBA8Unorm;
    unsigned rawBytes = packed16   ? 2 :
                        half4      ? 8 :
                        floatLanes ? 4 * floatLanes :
                                     4;
    assert(compact || texture.pixelFormat == MTLPixelFormatRGBA32Float);
    assert(!unsignedHalfMask || (half4 && unsignedHalfMask < 15));
    assert(texture.device == device && commands.commandBuffer);
    assert(level < texture.mipmapLevelCount);
    NSUInteger w = MAX(1ul, texture.width >> level);
    NSUInteger h = MAX(1ul, texture.height >> level);
    NSUInteger d = MAX(1ul, texture.depth >> level);
    NSUInteger row = (w * 16 + 255) & ~(NSUInteger)255;
    NSUInteger rawRow = (w * rawBytes + 255) & ~(NSUInteger)255;
    id<MTLBuffer> out =
        [device newBufferWithLength:row * h * d
                            options:MTLResourceStorageModeShared];
    id<MTLBuffer> raw =
        compact ? [device newBufferWithLength:rawRow * h * d
                                      options:MTLResourceStorageModePrivate] :
                  out;
    assert(out && raw);
    test_texture_require([commands addResource:texture error:&error], error);
    test_texture_require([commands addResource:out error:&error], error);
    test_texture_require([commands addResource:raw error:&error], error);
    if (compact && !pipeline) {
        id<MTL4Compiler> compiler =
            [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                        error:&error];
        test_texture_require(compiler != nil, error);
        MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
        ld.source =
            @"#include <metal_stdlib>\nusing namespace metal;\n"
             "kernel void expand(uint3 p [[thread_position_in_grid]], "
             "device const uchar *src [[buffer(0)]], "
             "device uint4 *dst [[buffer(1)]], "
             "constant uint *s [[buffer(2)]]) { "
             "if (p.x >= s[0] || p.y >= s[1] || p.z >= s[2]) return; "
             "uint index=(p.z*s[1]+p.y)*s[3]+p.x; "
             "uint4 bits; if(s[5]==7){"
             "bits=as_type<uint4>(max(float4(((device const char4*)src)[index])"
             "/127.0f,float4(-1)));"
             "}else if(s[5]>=4){uint v=((device const "
             "ushort*)src)[index];"
             "float4 color=s[5]==4 ? float4(float(v>>11)/31.0f,"
             "float((v>>5)&63)/63.0f,float(v&31)/31.0f,1) : "
             "s[5]==5 ? float4(float((v>>10)&31)/31.0f,"
             "float((v>>5)&31)/31.0f,float(v&31)/31.0f,float(v>>15)) : "
             "float4(float(v>>12)/15.0f,float((v>>8)&15)/15.0f,"
             "float((v>>4)&15)/15.0f,float(v&15)/15.0f);"
             "uint4 raw=as_type<uint4>(color);"
             "uint channels[6]={raw.x,raw.y,raw.z,raw.w,0,0x3f800000u};"
             "bits=uint4(channels[s[6]],channels[s[7]],channels[s[8]],"
             "channels[s[9]]);"
             "} else if (s[5] >= 2) { "
             "uint lanes=s[5]-1; device const uint *raw=(device const "
             "uint*)src; "
             "uint v[6]={raw[index*lanes],lanes==2 ? raw[index*lanes+1] : 0,"
             "0,0x3f800000u,0,0x3f800000u}; "
             "bits=uint4(v[s[6]],v[s[7]],v[s[8]],v[s[9]]); "
             "} else { float4 color=s[5] ? float4(((device const "
             "half4*)src)[index]) : float4(((device const "
             "uchar4*)src)[index])/255.0f; "
             "for(uint k=0;k<4;k++) if(s[10] & (1u<<k)) "
             "color[k]=(color[k]*256.0f)/255.0f; "
             "bits=as_type<uint4>(color); } "
             "dst[(p.z*s[1]+p.y)*s[4]+p.x] = bits; }";
        ld.options = [MTLCompileOptions new];
        ld.options.languageVersion = MTLLanguageVersion4_0;
        ld.options.mathMode = MTLMathModeSafe;
        ld.options.mathFloatingPointFunctions =
            MTLMathFloatingPointFunctionsPrecise;
        id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld
                                                              error:&error];
        test_texture_require(library != nil, error);
        MTL4LibraryFunctionDescriptor *fn = [MTL4LibraryFunctionDescriptor new];
        fn.library = library;
        fn.name = @"expand";
        MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
        pd.computeFunctionDescriptor = fn;
        pipeline = [compiler newComputePipelineStateWithDescriptor:pd
                                               compilerTaskOptions:nil
                                                             error:&error];
        test_texture_require(pipeline != nil, error);
        MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
        ad.maxBufferBindCount = 3;
        ad.initializeBindings = YES;
        arguments = [device newArgumentTableWithDescriptor:ad error:&error];
        test_texture_require(arguments != nil, error);
        pipelineDevice = device;
    }
    id<MTLBuffer> shape = nil;
    if (compact) {
        assert(device == pipelineDevice);
        MTLTextureSwizzleChannels swizzle = texture.swizzle;
        const uint32_t dimensions[] = {
            (uint32_t)w,
            (uint32_t)h,
            (uint32_t)d,
            (uint32_t)(rawRow / rawBytes),
            (uint32_t)(row / 16),
            snorm8     ? 7 :
            packed565  ? 4 :
            packed1555 ? 5 :
            packed4444 ? 6 :
            floatLanes ? floatLanes + 1 :
                         half4,
            test_texture_swizzle_index(swizzle.red),
            test_texture_swizzle_index(swizzle.green),
            test_texture_swizzle_index(swizzle.blue),
            test_texture_swizzle_index(swizzle.alpha),
            unsignedHalfMask
        };
        shape = [device newBufferWithBytes:dimensions
                                    length:sizeof(dimensions)
                                   options:MTLResourceStorageModeShared];
        assert(shape);
        test_texture_require([commands addResource:shape error:&error], error);
    }
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:texture
                     sourceSlice:face
                     sourceLevel:level
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(w, h, d)
                        toBuffer:raw
               destinationOffset:0
          destinationBytesPerRow:compact ? rawRow : row
        destinationBytesPerImage:(compact ? rawRow : row) * h
                         options:MTLBlitOptionNone];
    if (compact) {
        [e barrierAfterEncoderStages:MTLStageBlit
                 beforeEncoderStages:MTLStageDispatch
                   visibilityOptions:MTL4VisibilityOptionDevice];
        [arguments setAddress:raw.gpuAddress atIndex:0];
        [arguments setAddress:out.gpuAddress atIndex:1];
        [arguments setAddress:shape.gpuAddress atIndex:2];
        [e setComputePipelineState:pipeline];
        [e setArgumentTable:arguments];
        [e dispatchThreads:MTLSizeMake(w, h, d)
            threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    }
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return out;
}
static id<MTLBuffer> test_metal_read_texture(NV2AMetalCommands *commands,
                                             id<MTLTexture> texture,
                                             unsigned level, unsigned face)
{
    return test_metal_read_texture_decoded(commands, texture, level, face, 0);
}
/* Independent byte-to-float GPU expansion supplies the old decoded storage
 * contract to tests; production sampling does not use this helper. */
static __attribute__((unused)) id<MTLTexture>
test_metal_float_reference_decoded(NV2AMetalCommands *commands,
                                   id<MTLTexture> texture,
                                   unsigned unsignedHalfMask)
{
    assert(texture.pixelFormat == MTLPixelFormatRGBA16Float ||
           texture.pixelFormat == MTLPixelFormatB5G6R5Unorm ||
           texture.pixelFormat == MTLPixelFormatBGR5A1Unorm ||
           texture.pixelFormat == MTLPixelFormatABGR4Unorm ||
           texture.pixelFormat == MTLPixelFormatR32Float ||
           texture.pixelFormat == MTLPixelFormatRG32Float);
    NSError *error = nil;
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = texture.textureType;
    td.pixelFormat = MTLPixelFormatRGBA32Float;
    td.width = texture.width;
    td.height = texture.height;
    td.depth = texture.depth;
    td.mipmapLevelCount = texture.mipmapLevelCount;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> result = [commands.device newTextureWithDescriptor:td];
    assert(result);
    test_texture_require([commands addResource:result error:&error], error);
    for (unsigned face = 0;
         face < (texture.textureType == MTLTextureTypeCube ? 6u : 1u); face++) {
        for (unsigned level = 0; level < texture.mipmapLevelCount; level++) {
            NSUInteger w = MAX(1ul, texture.width >> level),
                       h = MAX(1ul, texture.height >> level),
                       d = MAX(1ul, texture.depth >> level);
            NSUInteger row = (w * 16 + 255) & ~(NSUInteger)255;
            id<MTLBuffer> values = test_metal_read_texture_decoded(
                commands, texture, level, face, unsignedHalfMask);
            id<MTL4ComputeCommandEncoder> e =
                [commands.commandBuffer computeCommandEncoder];
            assert(e);
            [e barrierAfterQueueStages:MTLStageAll
                          beforeStages:MTLStageBlit
                     visibilityOptions:MTL4VisibilityOptionDevice];
            [e copyFromBuffer:values
                       sourceOffset:0
                  sourceBytesPerRow:row
                sourceBytesPerImage:row * h
                         sourceSize:MTLSizeMake(w, h, d)
                          toTexture:result
                   destinationSlice:face
                   destinationLevel:level
                  destinationOrigin:MTLOriginMake(0, 0, 0)];
            [e barrierAfterStages:MTLStageAll
                beforeQueueStages:MTLStageAll
                visibilityOptions:MTL4VisibilityOptionDevice];
            [e endEncoding];
        }
    }
    return result;
}
static __attribute__((unused)) id<MTLTexture>
test_metal_float_reference(NV2AMetalCommands *commands, id<MTLTexture> texture)
{
    return test_metal_float_reference_decoded(commands, texture, 0);
}
#endif
