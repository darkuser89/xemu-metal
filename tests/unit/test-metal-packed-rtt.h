/* Every packed word through native RTT and the prior Float32 shader contract.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PACKED_RTT_H
#define TEST_METAL_PACKED_RTT_H

static id<MTLTexture> packed_rtt_reference(id<MTLTexture> input, BOOL opaque)
{
    static id<MTLComputePipelineState> pipeline;
    static id<MTL4ArgumentTable> arguments;
    NSError *error = nil;
    if (!pipeline) {
        id<MTL4Compiler> compiler = [commands.device
            newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                error:&error];
        require(compiler != nil, error);
        MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
        ld.source =
            @"#include <metal_stdlib>\nusing namespace metal;\n"
             "kernel void reference(texture2d<float,access::read> source "
             "[[texture(0)]],"
             "texture2d<float,access::write> target [[texture(1)]],"
             "constant uint &opaque [[buffer(0)]],uint2 p "
             "[[thread_position_in_grid]]) {"
             "if(p.x>=source.get_width()||p.y>=source.get_height()) return;"
             "float4 color=source.read(p);if(opaque) "
             "color.a=1;target.write(color,p);}";
        ld.options = [MTLCompileOptions new];
        ld.options.languageVersion = MTLLanguageVersion4_0;
        ld.options.mathMode = MTLMathModeSafe;
        id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld
                                                              error:&error];
        require(library != nil, error);
        MTL4LibraryFunctionDescriptor *fn = [MTL4LibraryFunctionDescriptor new];
        fn.library = library;
        fn.name = @"reference";
        MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
        pd.computeFunctionDescriptor = fn;
        pipeline = [compiler newComputePipelineStateWithDescriptor:pd
                                               compilerTaskOptions:nil
                                                             error:&error];
        require(pipeline != nil, error);
        MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
        ad.maxBufferBindCount = 1;
        ad.maxTextureBindCount = 2;
        ad.initializeBindings = YES;
        arguments = [commands.device newArgumentTableWithDescriptor:ad
                                                              error:&error];
        require(arguments != nil, error);
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:input.width
                                    height:input.height
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> output = [commands.device newTextureWithDescriptor:td];
    const uint32_t alpha = opaque;
    id<MTLBuffer> uniforms =
        [commands.device newBufferWithBytes:&alpha
                                     length:sizeof(alpha)
                                    options:MTLResourceStorageModeShared];
    assert(output && uniforms);
    require([commands addResource:input error:&error] &&
                [commands addResource:output error:&error] &&
                [commands addResource:uniforms error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageDispatch
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setComputePipelineState:pipeline];
    [arguments setTexture:input.gpuResourceID atIndex:0];
    [arguments setTexture:output.gpuResourceID atIndex:1];
    [arguments setAddress:uniforms.gpuAddress atIndex:0];
    [e setArgumentTable:arguments];
    [e dispatchThreads:MTLSizeMake(input.width, input.height, 1)
        threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return output;
}

static void packed_rtt_tests(void)
{
    NSError *error = nil;
    const unsigned formats[] = {
        NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5,
    };
    unsigned cases = 0;
    NSUInteger lanes = 0;
    NSUInteger packedBytes = 0, floatBytes = 0;
    for (unsigned f = 0; f < 3; f++) {
        for (unsigned scale = 1; scale <= 2; scale++) {
            for (unsigned swizzled = 0; swizzled < (f ? 1u : 2u); swizzled++) {
                cpu_write(0, 131072);
                uint16_t *words = surfaces.vram.contents;
                for (unsigned i = 0; i < 65536; i++)
                    words[i] = i;
                [textures removeAllTextures];
                NV2AMetalSurfaceConfig config = {
                    .format = formats[f],
                    .width = 256,
                    .height = 256,
                    .pitch = 512,
                    .scale = scale,
                    .color = YES,
                    .swizzle = swizzled,
                };
                NV2AMetalCachedSurface *s =
                    [surfaces prepareSurfaceAtAddress:0
                                               config:&config
                                                frame:1
                                                error:&error];
                require(s != nil, error);
                NV2AMetalTextureSource src = {
                    .length = 131072,
                    .shape =
                        {
                            .format =
                                f ? NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5
                                : swizzled
                                    ? NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R5G6B5
                                    : NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5,
                            .dimension = 2,
                            .width = 256,
                            .height = 256,
                            .depth = 1,
                            .levels = 1,
                            .pitch = 512,
                        },
                };
                NV2AMetalCachedTexture *t = prepare(src);
                assert(t.binding.texture.pixelFormat ==
                       (f ? MTLPixelFormatBGR5A1Unorm
                          : MTLPixelFormatB5G6R5Unorm));
                assert(t.scale == scale && prepare(src) == t);
                id<MTLTexture> reference =
                    packed_rtt_reference(s.transfer.texture, f != 0);
                id<MTLBuffer> expected =
                    test_metal_read_2d_texture(commands, reference, 0);
                id<MTLBuffer> actual =
                    test_metal_read_2d_texture(commands, t.binding.texture, 0);
                finish();
                require([t validateCompletedWithError:&error], error);
                assert(
                    actual.length == expected.length &&
                    !memcmp(actual.contents, expected.contents, actual.length));
                lanes += actual.length / 4;
                if (!f && !swizzled && scale == 2) {
                    packedBytes = t.binding.texture.allocatedSize;
                    floatBytes = reference.allocatedSize;
                }
                NSData *snapshot = nv2a_metal_texture_snapshot(
                    t.binding.texture, commands, &error);
                require(snapshot != nil, error);
                assert(snapshot.length == 40 + t.binding.texture.width *
                                                   t.binding.texture.height *
                                                   2);
                const uint8_t *wire = snapshot.bytes;
                assert(wire[39] == (f ? 11 : 9));
                NSData *sourceWords = nv2a_metal_texture_snapshot(
                    s.transfer.texture, commands, &error);
                require(sourceWords != nil, error);
                assert(sourceWords.length == snapshot.length &&
                       !memcmp((const uint8_t *)sourceWords.bytes + 40,
                               wire + 40, snapshot.length - 40));
                id<MTLTexture> restored =
                    nv2a_metal_texture_restore(snapshot, commands, &error);
                require(restored != nil, error);
                require([commands beginWithError:&error] != nil, error);
                id<MTLBuffer> restoredPixels =
                    test_metal_read_2d_texture(commands, restored, 0);
                require([commands submitWithError:&error] &&
                            [commands waitUntilIdleWithError:&error],
                        error);
                assert(restoredPixels.length == expected.length &&
                       !memcmp(restoredPixels.contents, expected.contents,
                               expected.length));
                NSData *again =
                    nv2a_metal_texture_snapshot(restored, commands, &error);
                require(again != nil, error);
                assert([again isEqualToData:snapshot]);
                cases++;
            }
        }
    }
    printf("Packed RTT: %u cases, all 65536 words per layout, %lu bit-exact "
           "native-vs-Float32 lanes, packed restore/resave; "
           "512x512 packed/Float32 allocation %lu/%lu bytes PASS\n",
           cases, (unsigned long)lanes, (unsigned long)packedBytes,
           (unsigned long)floatBytes);
    checks++;
}
#endif
