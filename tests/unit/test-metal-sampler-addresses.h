/* Shared linear-tap addresses versus the original manual level algorithm.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SAMPLER_ADDRESSES_H
#define TEST_METAL_SAMPLER_ADDRESSES_H

typedef struct SamplerAddressPacket {
    NV2AMetalSamplingUniforms sampling;
    uint32_t halfMask, count;
    float gradients[2][4];
} SamplerAddressPacket;
_Static_assert(sizeof(SamplerAddressPacket) == 92, "sampling packet");

static NSString *sa_source(unsigned variant)
{
    /* Use the actual generated production source. The reference restores
     * only the pre-optimization texel/level functions; footprint, mip choice,
     * conversion, cube code and compiler options remain shared. */
    NSString *source = @(metal_shader_source);
    NSString *begin =
        @"template <typename T>\nstatic float4 sample_addressed_texel(";
    NSString *end = @"template <typename T>\nstatic float4 sample_mips(";
    assert([source componentsSeparatedByString:begin].count == 2);
    assert([source componentsSeparatedByString:end].count == 2);
    NSString *linearRead = @"color += w * sample_addressed_texel(\n"
                            "                    t, int3(ax[x], ay[y], az[z]), "
                            "size, level, face, s,\n"
                            "                    unsigned_half_mask);";
    assert([source componentsSeparatedByString:linearRead].count == 2);
    if (variant == 1) {
        NSRange start = [source rangeOfString:begin],
                stop = [source rangeOfString:end];
        assert(stop.location > start.location);
        NSString *reference =
            @"template <typename T>\n"
             "static float4 sample_texel(T t, int3 c, uint3 size, uint level, "
             "uint face,\n"
             "                           constant NV2AMetalSamplingUniforms "
             "&s,\n"
             "                           uint unsigned_half_mask)\n"
             "{\n"
             "    for (uint i = 0; i < 3; i++) {\n"
             "        c[i] = sample_address(c[i], size[i], s.address[i]);\n"
             "    }\n"
             "    if (any(c < 0) || any(c >= int3(size))) {\n"
             "        return float4(s.border_color[0], s.border_color[1], "
             "s.border_color[2],\n"
             "                      s.border_color[3]);\n"
             "    }\n"
             "    float4 value = sample_read(t, uint3(c), level, face);\n"
             "    for (uint k = 0; k < 4; k++)\n"
             "        if (unsigned_half_mask & (1u << k))\n"
             "            value[k] = (value[k] * 256.0f) / 255.0f;\n"
             "    return value;\n"
             "}\n\n"
             "template <typename T>\n"
             "static float4 sample_level(T t, float3 c, uint level, uint face, "
             "bool linear,\n"
             "                           bool volume, constant "
             "NV2AMetalSamplingUniforms &s,\n"
             "                           uint unsigned_half_mask)\n"
             "{\n"
             "    uint3 size = sample_size(t, level);\n"
             "    for (uint i = 0; i < 3; i++) {\n"
             "        c[i] = sample_coordinate(c[i], s.address[i]);\n"
             "    }\n"
             "    float3 p = c * float3(size);\n"
             "    if (!linear) {\n"
             "        return sample_texel(t, int3(floor(p)), size, level, "
             "face, s,\n"
             "                            unsigned_half_mask);\n"
             "    }\n"
             "    p -= .5f;\n"
             "    int3 base = int3(floor(p));\n"
             "    float3 f = p - floor(p);\n"
             "    if (!volume) {\n"
             "        base.z = 0;\n"
             "    }\n"
             "    float4 color = 0;\n"
             "    for (uint z = 0; z < (volume ? 2u : 1u); z++) {\n"
             "        for (uint y = 0; y < 2; y++) {\n"
             "            for (uint x = 0; x < 2; x++) {\n"
             "                float w = (x ? f.x : 1 - f.x) * (y ? f.y : 1 - "
             "f.y);\n"
             "                if (volume) {\n"
             "                    w *= z ? f.z : 1 - f.z;\n"
             "                }\n"
             "                color += w * sample_texel(t, base + int3(x, y, "
             "z), size, level,\n"
             "                                          face, s, "
             "unsigned_half_mask);\n"
             "            }\n"
             "        }\n"
             "    }\n"
             "    return color;\n"
             "}\n\n";
        source = [source
            stringByReplacingCharactersInRange:NSMakeRange(start.location,
                                                           stop.location -
                                                               start.location)
                                    withString:reference];
    } else if (variant == 2) {
        /* A changed linear-only call site must be observable on every texture
         * kind. Nearest controls must still match the real production path. */
        NSString *guard = @"static bool sample_collapsed_taps(";
        NSString *level = @"template <typename T>\nstatic float4 sample_level(";
        NSRange a = [source rangeOfString:guard], b = [source rangeOfString:level];
        assert(a.location != NSNotFound && b.location > a.location);
        source = [source stringByReplacingCharactersInRange:
                             NSMakeRange(a.location, b.location - a.location)
                                                  withString:
                             @"static bool sample_collapsed_taps(int2 ax, int2 ay, int2 az)\n"
                              "{ return false; }\n\n"];
        source = [source
            stringByReplacingOccurrencesOfString:linearRead
                                      withString:@"color += w * float4(271, "
                                                 @"131, 47, 19);"];
    }
    NSMutableString *result = [source mutableCopy];
    [result
        appendString:@"\nstruct SAPacket { NV2AMetalSamplingUniforms sampling; "
                     @"uint halfMask,count; float gradients[2][4]; };\n"];
    NSArray *types =
        @[ @"texture2d<float>", @"texture3d<float>", @"texturecube<float>" ];
    for (unsigned kind = 0; kind < 3; kind++)
        [result appendFormat:
                    @"kernel void sampler_addresses%u(%@ t [[texture(0)]], "
                    @"device const float4 *c [[buffer(0)]], device float4 *out "
                    @"[[buffer(1)]], constant SAPacket &p [[buffer(2)]], uint "
                    @"i [[thread_position_in_grid]]) { if(i >= p.count) "
                    @"return; out[i] = sample_footprint(t, c[i].xyz, "
                    @"float3(p.gradients[0][0],p.gradients[0][1],p.gradients[0]"
                    @"[2]), "
                    @"float3(p.gradients[1][0],p.gradients[1][1],p.gradients[1]"
                    @"[2]), %@, %@, p.sampling, p.halfMask, "
                    @"sample_base_only(p.sampling)); }\n",
                    kind, types[kind], kind == 2 ? @"uint(c[i].w)" : @"0",
                    kind == 1 ? @"true" : @"false"];
    return result;
}

static id<MTLTexture> sa_texture(unsigned kind, unsigned shape, unsigned format,
                                 BOOL special)
{
    const MTLPixelFormat formats[] = {
        MTLPixelFormatRGBA32Float, MTLPixelFormatRGBA16Float,
        MTLPixelFormatRGBA8Unorm,  MTLPixelFormatRGBA8Snorm,
        MTLPixelFormatB5G6R5Unorm, MTLPixelFormatRGBA32Float
    };
    unsigned width = shape == 0 ? 8 : shape == 1 ? 7 : shape == 2 ? 1 : 16;
    unsigned height = shape == 2 ? 8 : shape == 3 ? 1 : width;
    unsigned depth = kind == 1 ? (shape == 1 ? 5 : shape == 2 ? 1 : 4) : 1;
    if (kind == 2)
        height = width;
    MTLTextureDescriptor *d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[format]
                                                           width:width
                                                          height:height
                                                       mipmapped:YES];
    d.textureType = kind == 1 ? MTLTextureType3D :
                    kind == 2 ? MTLTextureTypeCube :
                                MTLTextureType2D;
    d.depth = depth;
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageShaderRead;
    unsigned extent = MAX(MAX(width, height), depth), levels = 1;
    while (extent > 1) {
        levels++;
        extent >>= 1;
    }
    d.mipmapLevelCount = levels;
    id<MTLTexture> texture = [commands.device newTextureWithDescriptor:d];
    assert(texture);
    const uint32_t bits[] = { 0,          0x80000000, 1,          0x80000001,
                              0x7f800000, 0xff800000, 0x7fc00005, 0x7f7fffff };
    unsigned bytes = format == 0 || format == 5 ? 16 :
                     format == 1                ? 8 :
                     format == 4                ? 2 :
                                                  4;
    for (unsigned face = 0; face < (kind == 2 ? 6u : 1u); face++)
        for (unsigned level = 0; level < levels; level++) {
            unsigned w = MAX(1u, width >> level), h = MAX(1u, height >> level),
                     z = MAX(1u, depth >> level);
            NSMutableData *data =
                [NSMutableData dataWithLength:w * h * z * bytes];
            uint8_t *p = data.mutableBytes;
            for (unsigned i = 0; i < w * h * z; i++)
                for (unsigned k = 0; k < (format == 4 ? 1u : 4u); k++) {
                    unsigned raw =
                        (i * 37 + face * 19 + level * 23 + k * 53) & 255;
                    float value = ((int)raw - 128) / 128.f;
                    if (format == 0) {
                        if (special && i % 3 == 0)
                            memcpy(&value, &bits[(i + k) % 8], 4);
                        memcpy(p + 16 * i + 4 * k, &value, 4);
                    } else if (format == 1) {
                        uint16_t word;
                        _Float16 half = value;
                        if (special && i % 3 == 0) {
                            const uint16_t halfBits[] = { 0,      0x8000,
                                                          1,      0x8001,
                                                          0x7c00, 0xfc00,
                                                          0x7e05, 0x7bff };
                            word = halfBits[(i + k) % 8];
                        } else
                            memcpy(&word, &half, 2);
                        memcpy(p + 8 * i + 2 * k, &word, 2);
                    } else if (format == 4) {
                        uint16_t word =
                            (i * 1013 + face * 731 + level * 77) & 65535;
                        memcpy(p + 2 * i, &word, 2);
                    } else if (format == 5) {
                        /* Signed HILO16's decoded float domain: B mirrors LO
                         * and alpha is opaque; no upload/swizzle is modeled. */
                        unsigned component = k == 2 ? 1 : k;
                        unsigned code = (i * 12337 + face * 71 + level * 31 +
                                         component * 911) &
                                        65535;
                        value = k == 3 ? 1 :
                                         (code >= 32768 ? (int)code - 65536 :
                                                          (int)code) /
                                             32768.f;
                        memcpy(p + 16 * i + 4 * k, &value, 4);
                    } else
                        p[4 * i + k] = raw;
                }
            [texture replaceRegion:MTLRegionMake3D(0, 0, 0, w, h, z)
                       mipmapLevel:level
                             slice:face
                         withBytes:data.bytes
                       bytesPerRow:w * bytes
                     bytesPerImage:w * h * bytes];
        }
    return texture;
}

static id<MTLBuffer> sa_coordinates(BOOL special)
{
    float coordinates[384][4];
    const float edges[] = { -2.5f,  -1,         -.00001f, 0,
                            .0625f, .49999997f, .5f,      .50000006f,
                            1,      1.00001f,   2,        1e20f };
    const uint32_t bits[] = { 0,          0x80000000, 1,          0x80000001,
                              0x00800000, 0x7f7fffff, 0xff7fffff, 0x7f800000,
                              0xff800000, 0x7fc00005 };
    for (unsigned i = 0; i < 384; i++) {
        for (unsigned k = 0; k < 3; k++) {
            coordinates[i][k] =
                edges[(i + k * 3) % (sizeof(edges) / sizeof(*edges))];
            if (special && i % 3 == 0)
                memcpy(&coordinates[i][k],
                       &bits[(i + k) % (sizeof(bits) / sizeof(*bits))], 4);
        }
        coordinates[i][3] = i % 6;
    }
    return [commands.device newBufferWithBytes:coordinates
                                        length:sizeof(coordinates)
                                       options:MTLResourceStorageModeShared];
}

static void sa_pair(id<MTLComputePipelineState> const pipelines[3],
                    id<MTLTexture> texture, id<MTLBuffer> coordinates,
                    SamplerAddressPacket packet, BOOL control, unsigned ordinal)
{
    NSError *error = nil;
    id<MTLBuffer> uniform =
        [commands.device newBufferWithBytes:&packet
                                     length:sizeof(packet)
                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> outputs[3];
    require(uniform && [commands beginWithError:&error], error);
    for (id resource in @[ uniform, coordinates, texture ])
        require([commands addResource:resource error:&error], error);
    MTL4ArgumentTableDescriptor *d = [MTL4ArgumentTableDescriptor new];
    d.maxBufferBindCount = 3;
    d.maxTextureBindCount = 1;
    d.initializeBindings = YES;
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageAll
                   visibilityOptions:MTL4VisibilityOptionDevice];
    for (unsigned variant = 0; variant < (control ? 3u : 2u); variant++) {
        outputs[variant] =
            [commands.device newBufferWithLength:packet.count * 16
                                         options:MTLResourceStorageModeShared];
        id<MTL4ArgumentTable> arguments =
            [commands.device newArgumentTableWithDescriptor:d error:&error];
        require(outputs[variant] && arguments &&
                    [commands addResource:outputs[variant] error:&error] &&
                    [commands keepAlive:arguments error:&error] &&
                    [commands keepAlive:pipelines[variant] error:&error],
                error);
        [arguments setAddress:coordinates.gpuAddress atIndex:0];
        [arguments setAddress:outputs[variant].gpuAddress atIndex:1];
        [arguments setAddress:uniform.gpuAddress atIndex:2];
        [arguments setTexture:texture.gpuResourceID atIndex:0];
        [encoder setArgumentTable:arguments];
        [encoder setComputePipelineState:pipelines[variant]];
        [encoder dispatchThreads:MTLSizeMake(packet.count, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    }
    [encoder barrierAfterStages:MTLStageAll
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    if (memcmp(outputs[0].contents, outputs[1].contents, packet.count * 16)) {
        fprintf(stderr,
                "Sampler addresses case%u differs from old level algorithm\n",
                ordinal);
        abort();
    }
    if (control) {
        BOOL different = memcmp(outputs[0].contents, outputs[2].contents,
                                packet.count * 16) != 0;
        assert(different == !!packet.sampling.min_linear);
    }
}

static void sampler_addresses_tests(void)
{
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    id<MTLComputePipelineState> pipelines[3][3];
    for (unsigned variant = 0; variant < 3; variant++) {
        MTL4LibraryDescriptor *d = [MTL4LibraryDescriptor new];
        d.source = sa_source(variant);
        d.options = [MTLCompileOptions new];
        d.options.languageVersion = MTLLanguageVersion4_0;
        d.options.mathMode = MTLMathModeSafe;
        d.options.mathFloatingPointFunctions =
            MTLMathFloatingPointFunctionsPrecise;
        id<MTLLibrary> library = [compiler newLibraryWithDescriptor:d
                                                              error:&error];
        require(library != nil, error);
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
    id<MTLBuffer> coordinates[2] = { sa_coordinates(NO), sa_coordinates(YES) };
    unsigned cases = 0, controls = 0;
    for (unsigned kind = 0; kind < 3; kind++) {
        id<MTLTexture> texture = sa_texture(kind, 0, 0, NO);
        for (unsigned linear = 0; linear < 2; linear++) {
            SamplerAddressPacket packet = { .sampling = { .enabled = 1,
                                                          .address = { 1, 1,
                                                                       1 },
                                                          .min_linear = linear,
                                                          .mag_linear = linear,
                                                          .anisotropy = 1 },
                                            .count = 384 };
            sa_pair(pipelines[kind], texture, coordinates[0], packet, YES,
                    cases);
            controls++;
        }
    }
    for (unsigned kind = 0; kind < 3; kind++)
        for (unsigned shape = 0; shape < 4; shape++)
            for (unsigned format = 0; format < 6; format++)
                for (unsigned special = 0; special < (format < 2 ? 2u : 1u);
                     special++)
                    @autoreleasepool {
                        id<MTLTexture> texture =
                            sa_texture(kind, shape, format, special);
                        for (unsigned address = 0; address < 8; address++)
                            for (unsigned profile = 0; profile < 5; profile++) {
                                SamplerAddressPacket packet = {
                                    .sampling = { .enabled = 1,
                                                  .min_linear = 1,
                                                  .mag_linear = 1,
                                                  .anisotropy = 1,
                                                  .border_color = { -0.f, .125f,
                                                                    -.25f,
                                                                    1 } },
                                    .count = 384
                                };
                                for (unsigned k = 0; k < 3; k++)
                                    packet.sampling.address[k] =
                                        address < 5 ? address + 1 :
                                                      1 + (address + k * 2) % 5;
                                if (profile) {
                                    packet.sampling.mip_filter =
                                        profile == 1 ? 1 : 2;
                                    packet.sampling.anisotropy =
                                        profile == 3 ? 8 :
                                        profile == 4 ? 4 :
                                                       1;
                                    packet.sampling.lod_bias = .00390625f;
                                    packet.gradients[0][0] = .75f;
                                    packet.gradients[0][1] = .0625f;
                                    packet.gradients[1][1] = .125f;
                                    packet.gradients[1][2] = .03125f;
                                }
                                if (address == 5)
                                    packet.sampling.min_linear =
                                        packet.sampling.mag_linear = 0;
                                packet.halfMask =
                                    format == 1 ?
                                        (unsigned[]){ 0, 5, 10,
                                                      15 }[address % 4] :
                                        0;
                                if (address == 6) {
                                    packet.gradients[0][0] = INFINITY;
                                    packet.gradients[1][1] = NAN;
                                }
                                if (address == 7) {
                                    packet.gradients[0][0] = 0x1.fffffep127f;
                                    packet.gradients[1][1] = -0x1.fffffep127f;
                                }
                                sa_pair(pipelines[kind], texture,
                                        coordinates[special], packet, NO,
                                        cases++);
                            }
                    }
    assert(cases == 3840 && controls == 6);
    printf("Sampler addresses: %u bit-exact original-level Float4 pairs/%u "
           "pixels; POT/NPOT/1xN, 2D/3D/cube faces, five/mixed addresses, "
           "nearest/linear/mip/AF, raw half masks/HILO float "
           "domain/NaN/Inf/zero/subnormals/extreme gradients; %u live "
           "linear/nearest controls PASS\n",
           cases, cases * 384, controls);
    puts("Sampler address oracle: explicit gradients and cube face/UV; cube "
         "projection, derivatives, uploads and guest timing are outside this "
         "matrix");
}
#endif
