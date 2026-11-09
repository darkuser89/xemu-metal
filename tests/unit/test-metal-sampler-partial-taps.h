/* Partial addressed-tap reuse against the exact full-collapse baseline and
 * the independent original level algorithm. SPDX-License-Identifier:
 * LGPL-2.0-or-later */
#ifndef TEST_METAL_SAMPLER_PARTIAL_TAPS_H
#define TEST_METAL_SAMPLER_PARTIAL_TAPS_H

static NSRange spt_block(NSString *source, NSString *marker, BOOL helper)
{
    assert([source componentsSeparatedByString:marker].count == 2);
    NSRange a = [source rangeOfString:marker];
    NSRange b = [source
        rangeOfString:@"{"
              options:0
                range:NSMakeRange(a.location, source.length - a.location)];
    assert(b.location != NSNotFound);
    NSUInteger depth = 1, end = NSMaxRange(b);
    while (depth && end < source.length) {
        unichar c = [source characterAtIndex:end++];
        depth += c == '{';
        depth -= c == '}';
    }
    assert(!depth && end < source.length &&
           [source characterAtIndex:end] == '\n');
    end++;
    if (helper) {
        assert(end < source.length && [source characterAtIndex:end] == '\n');
        end++;
    }
    return NSMakeRange(a.location, end - a.location);
}

/* Variant1 reverses ONLY this optimization, including its helper comment.
 * The complete sampler then equals SHA941540's 12919 bytes. Variants2/3 are
 * routing controls, not numerical references or texture-read counters. */
static NSString *spt_source(NSString *production, unsigned variant)
{
    assert(variant < 4);
    if (!variant)
        return production;
    NSString *helper =
        @"/* A non-volume sample never repeats a z contribution.";
    NSString *branch = @"    if (sample_partial_taps(ax, ay, az, volume)) {";
    NSMutableString *source = [production mutableCopy];
    if (variant == 1) {
        [source deleteCharactersInRange:spt_block(source, branch, NO)];
        [source deleteCharactersInRange:spt_block(source, helper, YES)];
        assert([source lengthOfBytesUsingEncoding:NSUTF8StringEncoding] +
                   2462 ==
               [production lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    } else if (variant == 2) {
        NSRange block = spt_block(source, helper, YES);
        NSRange open = [source rangeOfString:@"{" options:0 range:block];
        [source replaceCharactersInRange:NSMakeRange(NSMaxRange(open),
                                                     NSMaxRange(block) -
                                                         NSMaxRange(open))
                              withString:@"\n    return false;\n}\n\n"];
    } else {
        NSString *read = @"float4 t00 = sample_addressed_texel(t, int3(ax.x, "
                         @"ay.x, az.x), size,\n"
                          "                                            level, "
                          "face, s, unsigned_half_mask);";
        assert([source componentsSeparatedByString:read].count == 2);
        [source
            replaceOccurrencesOfString:read
                            withString:@"float4 t00 = float4(271, 131, 47, 19);"
                               options:0
                                 range:NSMakeRange(0, source.length)];
    }
    return source;
}
static NSString *sampler_partial_taps_source(NSString *source, BOOL reference)
{
    return spt_source(source, reference ? 1 : 0);
}
static NSString *spt_kernel_source(unsigned variant)
{
    if (variant == 2)
        return sa_source(
            1); /* Unchanged independent pre-addressed level code. */
    NSString *source = sa_source(0);
    if (variant == 1)
        return sampler_partial_taps_source(source, YES);
    if (variant == 3)
        return spt_source(source, 2);
    if (variant == 4)
        return spt_source(source, 3);
    if (variant >= 5) {
        source = sst_guard_off(source); /* Full collapse OFF independently. */
        return spt_source(source, variant == 5 ? 3 : 2);
    }
    return source;
}

typedef struct SamplerPartialShape {
    unsigned kind, width, height, depth, coordinate;
    BOOL partial;
} SamplerPartialShape;
static const SamplerPartialShape spt_shapes[] = {
    { 0, 1, 8, 1, 0, YES }, { 0, 8, 1, 1, 1, YES },  { 0, 8, 8, 1, 2, YES },
    { 0, 8, 8, 1, 3, NO },  { 1, 8, 8, 1, 4, YES },  { 1, 1, 8, 8, 5, YES },
    { 1, 8, 1, 8, 6, YES }, { 1, 1, 1, 8, 7, YES },  { 1, 8, 1, 1, 8, YES },
    { 1, 8, 8, 8, 9, NO },  { 2, 8, 8, 1, 10, YES }, { 2, 8, 8, 1, 11, NO }
};

static id<MTLTexture> spt_texture(SamplerPartialShape shape, unsigned format,
                                  BOOL special, BOOL mipmapped)
{
    const MTLPixelFormat formats[] = {
        MTLPixelFormatRGBA32Float, MTLPixelFormatRGBA16Float,
        MTLPixelFormatRGBA8Unorm,  MTLPixelFormatRGBA8Snorm,
        MTLPixelFormatB5G6R5Unorm, MTLPixelFormatRGBA32Float
    };
    MTLTextureDescriptor *d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[format]
                                                           width:shape.width
                                                          height:shape.height
                                                       mipmapped:mipmapped];
    d.textureType = shape.kind == 1 ? MTLTextureType3D :
                    shape.kind == 2 ? MTLTextureTypeCube :
                                      MTLTextureType2D;
    d.depth = shape.depth;
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageShaderRead;
    unsigned levels = 1;
    if (mipmapped)
        for (unsigned n = MAX(MAX(shape.width, shape.height), shape.depth);
             n > 1; n >>= 1)
            levels++;
    d.mipmapLevelCount = levels;
    id<MTLTexture> texture = [commands.device newTextureWithDescriptor:d];
    require(texture != nil, nil);
    const uint32_t raw[] = { 0,          0x80000000, 1,          0x80000001,
                             0x7f800000, 0xff800000, 0x7fc00005, 0x00800000 };
    const uint16_t halfRaw[] = { 0,      0x8000, 1,      0x8001,
                                 0x7c00, 0xfc00, 0x7e05, 0x0400 };
    unsigned bytes = format == 0 || format == 5 ? 16 :
                     format == 1                ? 8 :
                     format == 4                ? 2 :
                                                  4;
    for (unsigned face = 0; face < (shape.kind == 2 ? 6u : 1u); face++)
        for (unsigned level = 0; level < levels; level++) {
            unsigned w = MAX(1u, shape.width >> level),
                     h = MAX(1u, shape.height >> level),
                     z = MAX(1u, shape.depth >> level);
            NSMutableData *data =
                [NSMutableData dataWithLength:(NSUInteger)w * h * z * bytes];
            uint8_t *p = data.mutableBytes;
            assert(p);
            for (unsigned i = 0; i < w * h * z; i++) {
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
                    if (format == 0) {
                        if (special && !(i % 3))
                            memcpy(&value, &raw[(i + k + face) % 8], 4);
                        memcpy(p + i * 16 + k * 4, &value, 4);
                    } else if (format == 1) {
                        _Float16 half = value;
                        uint16_t word;
                        memcpy(&word, &half, 2);
                        if (special && !(i % 3))
                            word = halfRaw[(i + k + face) % 8];
                        memcpy(p + i * 8 + k * 2, &word, 2);
                    } else if (format == 5) {
                        unsigned component = k == 2 ? 1 : k;
                        unsigned word = (i * 12337 + face * 71 + level * 31 +
                                         component * 911 + 8193) &
                                        65535;
                        value = k == 3 ? 1 :
                                         (word >= 32768 ? (int)word - 65536 :
                                                          (int)word) /
                                             32768.f;
                        memcpy(p + i * 16 + k * 4, &value, 4);
                    } else
                        p[i * 4 + k] = code;
                }
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

static id<MTLBuffer> spt_coordinates(SamplerPartialShape shape, BOOL special)
{
    float coordinates[64][4];
    const uint32_t raw[] = { 0,          0x80000000, 1,          0x80000001,
                             0x7f800000, 0xff800000, 0x7fc00005, 0x00800000 };
    for (unsigned i = 0; i < 64; i++) {
        float a = .25f + (i % 7) / 16.f, b = .25f + ((i + 3) % 7) / 16.f;
        coordinates[i][0] = a;
        coordinates[i][1] = b;
        coordinates[i][2] = .375f + (i % 3) / 16.f;
        if (shape.width == 1)
            coordinates[i][0] = .375f;
        if (shape.height == 1)
            coordinates[i][1] = .375f;
        if (shape.depth == 1)
            coordinates[i][2] = .375f;
        if (shape.coordinate == 2 || shape.coordinate == 10)
            coordinates[i][0] = -.25f;
        if (special && i < 16)
            for (unsigned k = 0; k < 3; k++)
                memcpy(&coordinates[i][k], &raw[(i + k) % 8], 4);
        coordinates[i][3] = i % 6;
    }
    return [commands.device newBufferWithBytes:coordinates
                                        length:sizeof(coordinates)
                                       options:MTLResourceStorageModeShared];
}

static void spt_pair(id<MTLComputePipelineState> const pipelines[7],
                     id<MTLTexture> texture, id<MTLBuffer> coordinates,
                     SamplerAddressPacket packet, unsigned variants,
                     int expectedPartial, unsigned ordinal)
{
    NSError *error = nil;
    id<MTLBuffer> uniform =
        [commands.device newBufferWithBytes:&packet
                                     length:sizeof(packet)
                                    options:MTLResourceStorageModeShared];
    require(uniform && coordinates && [commands beginWithError:&error], error);
    for (id resource in @[ texture, uniform, coordinates ])
        require([commands addResource:resource error:&error], error);
    MTL4ArgumentTableDescriptor *d = [MTL4ArgumentTableDescriptor new];
    d.maxBufferBindCount = 3;
    d.maxTextureBindCount = 1;
    d.initializeBindings = YES;
    id<MTLBuffer> outputs[7];
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    for (unsigned v = 0; v < variants; v++) {
        outputs[v] =
            [commands.device newBufferWithLength:packet.count * 16
                                         options:MTLResourceStorageModeShared];
        id<MTL4ArgumentTable> args =
            [commands.device newArgumentTableWithDescriptor:d error:&error];
        require(outputs[v] && args &&
                    [commands addResource:outputs[v] error:&error] &&
                    [commands keepAlive:args error:&error] &&
                    [commands keepAlive:pipelines[v] error:&error],
                error);
        memset(outputs[v].contents, 0xcd, outputs[v].length);
        [args setAddress:coordinates.gpuAddress atIndex:0];
        [args setAddress:outputs[v].gpuAddress atIndex:1];
        [args setAddress:uniform.gpuAddress atIndex:2];
        [args setTexture:texture.gpuResourceID atIndex:0];
        [e setArgumentTable:args];
        [e setComputePipelineState:pipelines[v]];
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
    for (unsigned v = 1; v < variants; v++) {
        if (v == 4 || v == 5)
            continue;
        if (memcmp(outputs[0].contents, outputs[v].contents,
                   packet.count * 16)) {
            const uint32_t *a = outputs[0].contents, *b = outputs[v].contents;
            unsigned first = 0;
            while (first < packet.count * 4 && a[first] == b[first])
                first++;
            fprintf(stderr, "Partial taps case%u variant%u word%u %08x/%08x\n",
                    ordinal, v, first, a[first], b[first]);
            abort();
        }
    }
    if (expectedPartial >= 0) {
        BOOL reached = memcmp(outputs[0].contents, outputs[4].contents,
                              packet.count * 16) != 0;
        assert(reached == !!expectedPartial);
        if (variants == 7) {
            BOOL fullOff = memcmp(outputs[0].contents, outputs[5].contents,
                                  packet.count * 16) != 0;
            assert(fullOff == !!expectedPartial);
        }
    }
}

static void sampler_partial_taps_tests(void)
{
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    id<MTLComputePipelineState> pipelines[3][7];
    for (unsigned v = 0; v < 7; v++) {
        id<MTLLibrary> library = sst_library(compiler, spt_kernel_source(v));
        for (unsigned kind = 0; kind < 3; kind++) {
            MTL4LibraryFunctionDescriptor *f =
                [MTL4LibraryFunctionDescriptor new];
            f.library = library;
            f.name = [NSString stringWithFormat:@"sampler_addresses%u", kind];
            MTL4ComputePipelineDescriptor *d =
                [MTL4ComputePipelineDescriptor new];
            d.computeFunctionDescriptor = f;
            pipelines[kind][v] =
                [compiler newComputePipelineStateWithDescriptor:d
                                            compilerTaskOptions:nil
                                                          error:&error];
            require(pipelines[kind][v] != nil, error);
        }
    }
    unsigned pairs = 0;
    for (unsigned shape = 0; shape < sizeof(spt_shapes) / sizeof(spt_shapes[0]);
         shape++)
        for (unsigned format = 0; format < 6; format++)
            for (unsigned scene = 0; scene < 2; scene++)
                @autoreleasepool {
                    SamplerPartialShape s = spt_shapes[shape];
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
                    p.halfMask =
                        format == 1 ?
                            (unsigned[]){ 0, 5, 10, 15 }[(shape + scene) % 4] :
                            0;
                    if (scene) {
                        p.sampling.mip_filter = 2;
                        p.sampling.anisotropy = 4;
                        p.sampling.lod_bias = .25f;
                        p.gradients[0][0] = .5f;
                        p.gradients[1][1] = .125f;
                        for (unsigned k = 0; k < 3; k++)
                            p.sampling.address[k] = 1 + (shape + k) % 5;
                        const uint32_t border[] = { 0x80000000, 0x7f800000,
                                                    0x7fc00005, 1 };
                        memcpy(p.sampling.border_color, border, sizeof(border));
                    }
                    spt_pair(
                        pipelines[s.kind], spt_texture(s, format, scene, scene),
                        spt_coordinates(s, scene), p, 5,
                        format == 2 && !scene ? (int)s.partial : -1, pairs++);
                }
    for (unsigned kind = 0; kind < 3; kind++)
        for (unsigned profile = 0; profile < 5; profile++)
            @autoreleasepool {
                SamplerPartialShape s = {
                    kind, 8, 8, kind == 1 ? 8u : 1u, 3, NO
                };
                if (profile < 2)
                    s.width = s.height = s.depth = 1;
                if (profile == 2) {
                    s.width = 1;
                    if (kind == 2)
                        s.height = 1;
                }
                SamplerAddressPacket p = {
                    .sampling = { .enabled = 1,
                                  .min_linear = 1,
                                  .mag_linear = 1,
                                  .anisotropy = 1,
                                  .address = { 3, 3, 3 },
                                  .border_color = { -.25f, .125f, -0.f, 1 } },
                    .count = 64
                };
                if (profile == 1 || profile == 4)
                    p.sampling.min_linear = p.sampling.mag_linear = 0;
                if (profile == 3)
                    for (unsigned k = 0; k < 3; k++)
                        p.sampling.address[k] = 4;
                id<MTLBuffer> coords = spt_coordinates(s, NO);
                if (profile == 3) {
                    float *c = coords.contents;
                    for (unsigned i = 0; i < 64; i++)
                        c[4 * i] = c[4 * i + 1] = c[4 * i + 2] = -2;
                }
                BOOL partial = profile == 2 && kind != 2;
                spt_pair(pipelines[kind], spt_texture(s, 2, NO, NO), coords, p,
                         7, partial, pairs++);
            }
    assert(pairs == 159);
    printf("Partial taps:%u raw Float4 original941/independent-level/guard-OFF "
           "pairs; "
           "1xN/Nx1/3D axes/cube edge,normal "
           "az-only,border,mip/AF,half/HILO,NaN/Inf/zeros/subnormals; "
           "full/partial OFF and cache-poison routing controls only PASS\n",
           pairs);
}
#endif
