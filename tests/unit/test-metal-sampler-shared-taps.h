/* Shared addressed texels versus the independent original level algorithm.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SAMPLER_SHARED_TAPS_H
#define TEST_METAL_SAMPLER_SHARED_TAPS_H

static NSString *sst_guard_off(NSString *source)
{
    NSString *begin = @"static bool sample_collapsed_taps(";
    NSString *end = @"template <typename T>\nstatic float4 sample_level(";
    assert([source componentsSeparatedByString:begin].count == 2 &&
           [source componentsSeparatedByString:end].count == 2);
    NSRange a = [source rangeOfString:begin], b = [source rangeOfString:end];
    assert(b.location > a.location);
    return [source
        stringByReplacingCharactersInRange:NSMakeRange(a.location,
                                                       b.location - a.location)
                                withString:
                                    @"static bool sample_collapsed_taps(int2 "
                                    @"ax, int2 ay, int2 az)\n"
                                     "{ return false; }\n\n"];
}

static NSString *sst_source(unsigned variant)
{
    /* sa_source(1) contains the unchanged original, independently addressed
     * sample_texel/sample_level implementation, including all arithmetic. */
    NSString *source = sa_source(variant == 1 ? 1 : 0);
    if (variant == 2)
        return sst_guard_off(source);
    if (variant == 3) {
        NSString *read = @"float4 texel = sample_addressed_texel(t, int3(ax.x, "
                         @"ay.x, az.x), size,\n"
                          "                                              "
                          "level, face, s, unsigned_half_mask);";
        assert([source componentsSeparatedByString:read].count == 2);
        source = [source
            stringByReplacingOccurrencesOfString:read
                                      withString:@"float4 texel = float4(271, "
                                                 @"131, 47, 19);"];
    }
    return source;
}

static id<MTLLibrary> sst_library(id<MTL4Compiler> compiler, NSString *source)
{
    NSError *error = nil;
    MTL4LibraryDescriptor *d = [MTL4LibraryDescriptor new];
    d.source = source;
    d.options = [MTLCompileOptions new];
    d.options.languageVersion = MTLLanguageVersion4_0;
    d.options.mathMode = MTLMathModeSafe;
    d.options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:d error:&error];
    require(library != nil, error);
    return library;
}

static id<MTLTexture> sst_texture(unsigned kind, unsigned format,
                                  unsigned scene)
{
    const MTLPixelFormat formats[] = {
        MTLPixelFormatRGBA32Float, MTLPixelFormatRGBA16Float,
        MTLPixelFormatRGBA8Unorm,  MTLPixelFormatRGBA8Snorm,
        MTLPixelFormatB5G6R5Unorm, MTLPixelFormatRGBA32Float
    };
    unsigned size = scene ? 8 : 1, levels = scene ? 4 : 1;
    MTLTextureDescriptor *d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[format]
                                                           width:size
                                                          height:size
                                                       mipmapped:scene != 0];
    d.textureType = kind == 1 ? MTLTextureType3D :
                    kind == 2 ? MTLTextureTypeCube :
                                MTLTextureType2D;
    d.depth = kind == 1 ? size : 1;
    d.mipmapLevelCount = levels;
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [commands.device newTextureWithDescriptor:d];
    require(texture != nil, nil);
    const uint32_t bits[] = { 0,          0x80000000, 1,          0x80000001,
                              0x7f800000, 0xff800000, 0x7fc00005, 0x7f7fffff };
    const uint16_t halfBits[] = { 0,      0x8000, 1,      0x8001,
                                  0x7c00, 0xfc00, 0x7e05, 0x7bff };
    unsigned bytes = format == 0 || format == 5 ? 16 :
                     format == 1                ? 8 :
                     format == 4                ? 2 :
                                                  4;
    for (unsigned face = 0; face < (kind == 2 ? 6u : 1u); face++)
        for (unsigned level = 0; level < levels; level++) {
            unsigned w = MAX(1u, size >> level), z = kind == 1 ? w : 1;
            NSMutableData *data =
                [NSMutableData dataWithLength:w * w * z * bytes];
            uint8_t *p = data.mutableBytes;
            for (unsigned i = 0; i < w * w * z; i++) {
                if (format == 4) {
                    uint16_t word =
                        (i * 1013 + face * 731 + level * 77 + 19) & 65535;
                    memcpy(p + i * 2, &word, 2);
                    continue;
                }
                for (unsigned k = 0; k < 4; k++) {
                    unsigned code =
                        (i * 37 + face * 19 + level * 23 + k * 53) & 255;
                    float value = ((int)code - 128) / 128.f;
                    unsigned special = (k + (scene == 1 ? 4 : 0) + face) % 8;
                    if (format == 0) {
                        if (!(i % 3))
                            memcpy(&value, &bits[special], 4);
                        memcpy(p + i * 16 + k * 4, &value, 4);
                    } else if (format == 1) {
                        _Float16 half = value;
                        uint16_t word;
                        memcpy(&word, &half, 2);
                        if (!(i % 3))
                            word = halfBits[special];
                        memcpy(p + i * 8 + k * 2, &word, 2);
                    } else if (format == 5) {
                        unsigned component = k == 2 ? 1 : k;
                        unsigned raw = (i * 12337 + face * 71 + level * 31 +
                                        component * 911 + 8193) &
                                       65535;
                        value = k == 3 ? 1 :
                                         (raw >= 32768 ? (int)raw - 65536 :
                                                         (int)raw) /
                                             32768.f;
                        memcpy(p + i * 16 + k * 4, &value, 4);
                    } else
                        p[i * 4 + k] = code;
                }
            }
            [texture replaceRegion:MTLRegionMake3D(0, 0, 0, w, w, z)
                       mipmapLevel:level
                             slice:face
                         withBytes:data.bytes
                       bytesPerRow:w * bytes
                     bytesPerImage:w * w * bytes];
        }
    return texture;
}

static id<MTLBuffer> sst_coordinates(unsigned scene)
{
    float coordinates[64][4];
    const float edges[] = { -2.5f, -1,   -.00001f, 0,        .0625f, .25f,
                            .5f,   .75f, 1,        1.00001f, 2,      1e20f };
    const uint32_t bits[] = { 0,          0x80000000, 1,          0x80000001,
                              0x00800000, 0x7f800000, 0xff800000, 0x7fc00005 };
    for (unsigned i = 0; i < 64; i++) {
        for (unsigned k = 0; k < 3; k++) {
            coordinates[i][k] =
                scene == 2 ?
                    (i & 1 ? -100 : 100) :
                scene == 3 ?
                    (i % 3 ? .25f + .125f * ((i + k) % 3) :
                             (i & 1 ? -.25f : 1.25f)) :
                    edges[(i + k * 3) % (sizeof(edges) / sizeof(edges[0]))];
            if (scene != 2 && scene != 3 && !(i % 4))
                memcpy(&coordinates[i][k],
                       &bits[(i + k) % (sizeof(bits) / sizeof(bits[0]))], 4);
        }
        coordinates[i][3] = i % 6;
    }
    return [commands.device newBufferWithBytes:coordinates
                                        length:sizeof(coordinates)
                                       options:MTLResourceStorageModeShared];
}

static void sst_pair(id<MTLComputePipelineState> const pipelines[4],
                     id<MTLTexture> texture, id<MTLBuffer> coordinates,
                     SamplerAddressPacket packet, BOOL shared, unsigned ordinal)
{
    NSError *error = nil;
    id<MTLBuffer> uniform =
        [commands.device newBufferWithBytes:&packet
                                     length:sizeof(packet)
                                    options:MTLResourceStorageModeShared];
    require(uniform && coordinates && [commands beginWithError:&error], error);
    for (id resource in @[ uniform, coordinates, texture ])
        require([commands addResource:resource error:&error], error);
    MTL4ArgumentTableDescriptor *d = [MTL4ArgumentTableDescriptor new];
    d.maxBufferBindCount = 3;
    d.maxTextureBindCount = 1;
    d.initializeBindings = YES;
    id<MTLBuffer> outputs[4];
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    for (unsigned variant = 0; variant < 4; variant++) {
        outputs[variant] =
            [commands.device newBufferWithLength:packet.count * 16
                                         options:MTLResourceStorageModeShared];
        id<MTL4ArgumentTable> args =
            [commands.device newArgumentTableWithDescriptor:d error:&error];
        require(outputs[variant] && args &&
                    [commands addResource:outputs[variant] error:&error] &&
                    [commands keepAlive:args error:&error] &&
                    [commands keepAlive:pipelines[variant] error:&error],
                error);
        memset(outputs[variant].contents, 0xcd, outputs[variant].length);
        [args setAddress:coordinates.gpuAddress atIndex:0];
        [args setAddress:outputs[variant].gpuAddress atIndex:1];
        [args setAddress:uniform.gpuAddress atIndex:2];
        [args setTexture:texture.gpuResourceID atIndex:0];
        [e setArgumentTable:args];
        [e setComputePipelineState:pipelines[variant]];
        [e dispatchThreads:MTLSizeMake(packet.count, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    }
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    for (unsigned variant = 1; variant < 3; variant++)
        if (memcmp(outputs[0].contents, outputs[variant].contents,
                   packet.count * 16)) {
            const uint32_t *a = outputs[0].contents,
                           *b = outputs[variant].contents;
            unsigned first = 0;
            while (first < packet.count * 4 && a[first] == b[first])
                first++;
            fprintf(stderr, "Shared taps case%u reference%u word%u %08x/%08x\n",
                    ordinal, variant, first, a[first], b[first]);
            abort();
        }
    BOOL reached = memcmp(outputs[0].contents, outputs[3].contents,
                          packet.count * 16) != 0;
    if (reached != shared) {
        fprintf(stderr, "Shared taps control case%u actual%d expected%d\n",
                ordinal, reached, shared);
        abort();
    }
}

static void sampler_shared_taps_tests(void)
{
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    id<MTLComputePipelineState> pipelines[3][4];
    for (unsigned variant = 0; variant < 4; variant++) {
        id<MTLLibrary> library = sst_library(compiler, sst_source(variant));
        for (unsigned kind = 0; kind < 3; kind++) {
            MTL4LibraryFunctionDescriptor *f =
                [MTL4LibraryFunctionDescriptor new];
            f.library = library;
            f.name = [NSString stringWithFormat:@"sampler_addresses%u", kind];
            MTL4ComputePipelineDescriptor *p =
                [MTL4ComputePipelineDescriptor new];
            p.computeFunctionDescriptor = f;
            pipelines[kind][variant] =
                [compiler newComputePipelineStateWithDescriptor:p
                                            compilerTaskOptions:nil
                                                          error:&error];
            require(pipelines[kind][variant] != nil, error);
        }
    }
    unsigned pairs = 0;
    for (unsigned kind = 0; kind < 3; kind++)
        for (unsigned format = 0; format < 6; format++)
            for (unsigned scene = 0; scene < 4; scene++)
                @autoreleasepool {
                    SamplerAddressPacket p = {
                        .sampling = { .enabled = 1,
                                      .min_linear = 1,
                                      .mag_linear = 1,
                                      .anisotropy = 1,
                                      .address = { 3, 3, 3 },
                                      .border_color = { -0.f, .125f, -.25f,
                                                        1 } },
                        .count = 64
                    };
                    if (scene == 1) {
                        p.sampling.mip_filter = 2;
                        p.sampling.anisotropy = 8;
                        p.sampling.lod_bias = 4;
                        p.gradients[0][0] = 4;
                        p.gradients[1][1] = .5f;
                    } else if (scene == 2) {
                        p.sampling.mip_filter = 1;
                        p.sampling.anisotropy = 4;
                        p.gradients[0][0] = .75f;
                        p.gradients[1][1] = .125f;
                    } else if (scene == 3)
                        for (unsigned k = 0; k < 3; k++)
                            p.sampling.address[k] = 4;
                    p.halfMask =
                        format == 1 ? (unsigned[]){ 0, 5, 10, 15 }[scene] : 0;
                    sst_pair(pipelines[kind], sst_texture(kind, format, scene),
                             sst_coordinates(scene), p, scene != 3, pairs++);
                }
    for (unsigned kind = 0; kind < 3; kind++)
        for (unsigned profile = 0; profile < 8; profile++)
            @autoreleasepool {
                SamplerAddressPacket p = {
                    .sampling = { .enabled = 1,
                                  .min_linear = 1,
                                  .mag_linear = 1,
                                  .anisotropy = 1,
                                  .border_color = { -0.f, .125f, -.25f, 1 } },
                    .count = 64
                };
                BOOL shared = profile != 7;
                for (unsigned k = 0; k < 3; k++) {
                    unsigned address =
                        profile < 5 ? profile + 1 : 1 + (profile + k * 2) % 5;
                    p.sampling.address[k] = address;
                    if (k < (kind == 1 ? 3u : 2u) && address == 4)
                        shared = NO;
                }
                if (profile == 7)
                    p.sampling.min_linear = p.sampling.mag_linear = 0;
                /* Finite asymmetric texels make the control independent of
                 * NaN payload choices. These are branch witnesses, not GPU
                 * texture-read counters. */
                sst_pair(pipelines[kind], sst_texture(kind, 2, 0),
                         sst_coordinates(0), p, shared, pairs++);
            }
    assert(pairs == 96);
    printf(
        "Shared manual taps: %u bit-exact original-level/guard-OFF pairs; "
        "2D/3D/cube,1er base/mip,clamp corners/interior/border,all addresses,"
        "mip/AF,half masks/HILO/raw NaN/Inf/zero/subnormals; fast-read poison "
        "proves branch reachability only PASS\n",
        pairs);
}
#endif
