/* Native packed-format precision gate; no application or VM.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PACKED_NATIVE_H
#define TEST_METAL_PACKED_NATIVE_H

static void packed_native_probe(void)
{
    for (unsigned family = 0; family < 4; family++) {
        NSError *error = nil;
        NSMutableData *linear = [NSMutableData dataWithLength:65536 * 2];
        NSMutableData *swizzled = [NSMutableData dataWithLength:65536 * 2];
        for (unsigned v = 0; v < 65536; v++) {
            uint8_t *a = (uint8_t *)linear.mutableBytes + v * 2;
            uint8_t *b = (uint8_t *)swizzled.mutableBytes +
                         2 * morton(v % 256, v / 256, 0, 256, 256, 1);
            a[0] = b[0] = v;
            a[1] = b[1] = v >> 8;
        }
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:family == 0 ?
                                                   MTLPixelFormatB5G6R5Unorm :
                                               family == 3 ?
                                                   MTLPixelFormatABGR4Unorm :
                                                   MTLPixelFormatBGR5A1Unorm
                                         width:256
                                        height:256
                                     mipmapped:NO];
        if (family == 2)
            td.swizzle = MTLTextureSwizzleChannelsMake(
                MTLTextureSwizzleRed, MTLTextureSwizzleGreen,
                MTLTextureSwizzleBlue, MTLTextureSwizzleOne);
        if (family == 3)
            td.swizzle = MTLTextureSwizzleChannelsMake(
                MTLTextureSwizzleGreen, MTLTextureSwizzleBlue,
                MTLTextureSwizzleAlpha, MTLTextureSwizzleRed);
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> native = [commands.device newTextureWithDescriptor:td];
        assert(native);
        [native replaceRegion:MTLRegionMake2D(0, 0, 256, 256)
                  mipmapLevel:0
                    withBytes:linear.bytes
                  bytesPerRow:512];
        const unsigned formats[] = {
            NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R5G6B5,
            NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A1R5G5B5,
            NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5,
            NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A4R4G4B4
        };
        NV2AMetalTextureShape s = shape(formats[family]);
        s.width = s.height = 256;
        require([commands beginWithError:&error] != nil, error);
        id<MTLBuffer> guest = buffer(swizzled.bytes, swizzled.length);
        TextureUploadTestCommands *measured =
            (TextureUploadTestCommands *)commands;
        measured.scratchBytes = 0;
        measured.measureScratch = YES;
        NV2AMetalTextureUploadResult *uploaded = upload(s, guest, 0, nil, 0);
        measured.measureScratch = NO;
        assert(uploaded.texture.pixelFormat == td.pixelFormat);
        assert(measured.scratchBytes == 512 * 256);
        LaneCase c = { s.format, 0, 9, 2, NO };
        id<MTLTexture> reference = lane_float_decoder(s, c, guest, 0);
        id<MTLBuffer> out =
            [commands.device newBufferWithLength:65536 * 48
                                         options:MTLResourceStorageModeShared];
        assert(out);
        id<MTL4Compiler> compiler = [commands.device
            newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                error:&error];
        require(compiler != nil, error);
        MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
        ld.source =
            @"#include <metal_stdlib>\nusing namespace metal;\n"
             "kernel void packed_read(texture2d<float,access::read> a "
             "[[texture(0)]],"
             "texture2d<float,access::read> b [[texture(1)]],"
             "texture2d<float,access::read> c [[texture(2)]],"
             "device uint4 *out [[buffer(0)]],uint2 p "
             "[[thread_position_in_grid]]){"
             "uint i=p.y*256+p.x;out[i*3]=as_type<uint4>(a.read(p));"
             "out[i*3+1]=as_type<uint4>(b.read(p));out[i*3+2]=as_type<uint4>(c."
             "read(p));}";
        ld.options = [MTLCompileOptions new];
        ld.options.languageVersion = MTLLanguageVersion4_0;
        ld.options.mathMode = MTLMathModeSafe;
        ld.options.mathFloatingPointFunctions =
            MTLMathFloatingPointFunctionsPrecise;
        id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld
                                                              error:&error];
        require(library != nil, error);
        MTL4LibraryFunctionDescriptor *fn = [MTL4LibraryFunctionDescriptor new];
        fn.library = library;
        fn.name = @"packed_read";
        MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
        pd.computeFunctionDescriptor = fn;
        id<MTLComputePipelineState> pipeline =
            [compiler newComputePipelineStateWithDescriptor:pd
                                        compilerTaskOptions:nil
                                                      error:&error];
        require(pipeline != nil, error);
        MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
        ad.maxTextureBindCount = 3;
        ad.maxBufferBindCount = 1;
        ad.initializeBindings = YES;
        id<MTL4ArgumentTable> args =
            [commands.device newArgumentTableWithDescriptor:ad error:&error];
        require(args != nil, error);
        for (id<MTLResource> r in @[ native, reference, uploaded.texture, out ])
            require([commands addResource:r error:&error], error);
        require([commands keepAlive:args error:&error], error);
        require([commands keepAlive:pipeline error:&error], error);
        [args setTexture:native.gpuResourceID atIndex:0];
        [args setTexture:reference.gpuResourceID atIndex:1];
        [args setTexture:uploaded.texture.gpuResourceID atIndex:2];
        [args setAddress:out.gpuAddress atIndex:0];
        id<MTL4ComputeCommandEncoder> e =
            [commands.commandBuffer computeCommandEncoder];
        assert(e);
        [e barrierAfterQueueStages:MTLStageAll
                      beforeStages:MTLStageDispatch
                 visibilityOptions:MTL4VisibilityOptionDevice];
        [e setComputePipelineState:pipeline];
        [e setArgumentTable:args];
        [e dispatchThreads:MTLSizeMake(256, 256, 1)
            threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [e endEncoding];
        finish();
        unsigned differences = 0, maximumULP = 0;
        const uint32_t *bits = out.contents;
        for (unsigned v = 0; v < 65536; v++) {
            float expected[4] = { (v >> 11) / 31.f, ((v >> 5) & 63) / 63.f,
                                  (v & 31) / 31.f, 1 };
            if (family == 1 || family == 2) {
                expected[0] = ((v >> 10) & 31) / 31.f;
                expected[1] = ((v >> 5) & 31) / 31.f;
                expected[3] = family == 2 ? 1 : (float)(v >> 15);
            } else if (family == 3) {
                expected[0] = ((v >> 8) & 15) / 15.f;
                expected[1] = ((v >> 4) & 15) / 15.f;
                expected[2] = (v & 15) / 15.f;
                expected[3] = (v >> 12) / 15.f;
            }
            assert(!memcmp(bits + v * 12 + 4, expected, sizeof(expected)));
            for (unsigned k = 0; k < 4; k++) {
                uint32_t a = bits[v * 12 + k], b = bits[v * 12 + 4 + k];
                assert(bits[v * 12 + 8 + k] == b);
                differences += a != b;
                maximumULP = MAX(maximumULP, a > b ? a - b : b - a);
            }
        }
        printf("Packed family%u precision gate:65536 texels/262144 channels;"
               "native-versus-current differences=%u maximumULP=%u\n",
               family, differences, maximumULP);
        fflush(stdout);
        assert(!differences && !maximumULP);
        assert(uploaded.texture.allocatedSize * 8 <= reference.allocatedSize);
        printf("Packed family%u 256x256 scratch=131072/1048576 logical "
               "bytes;native/float allocated textures=%lu/%lu bytes PASS\n",
               family, (unsigned long)uploaded.texture.allocatedSize,
               (unsigned long)reference.allocatedSize);
    }
}
static void packed_layout_tests(void)
{
    NSError *error = nil;
    unsigned subresources = 0, texels = 0, filterPairs = lane_sample_pairs;
    const unsigned formats[4][2] = {
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R5G6B5,
          NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5 },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A1R5G5B5,
          NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5 },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5,
          NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5 },
        { NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A4R4G4B4,
          NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A4R4G4B4 }
    };
    for (unsigned family = 0; family < 4; family++)
        for (unsigned kind = 0; kind < 8; kind++) {
            @autoreleasepool {
                BOOL linear = kind == 0, small = kind == 7;
                NV2AMetalTextureShape s = shape(formats[family][linear]);
                s.dimension = kind == 2 || kind == 5 ? 3 : 2;
                s.cubemap = kind == 3 || kind == 6;
                s.border = kind >= 4 && kind <= 6;
                s.width = small ? 1 : linear ? 11 : 8;
                s.height = small ? 1 : linear ? 3 : s.cubemap ? 8 : 4;
                s.depth = s.dimension == 3 ? 2 : 1;
                s.levels = small || linear ? 1 : 4;
                s.max_level = s.levels - 1;
                s.pitch = 32;
                unsigned w = s.border ? 16 : s.width;
                unsigned h = s.border ? 16 : s.height;
                unsigned d = s.dimension == 3 ? (s.border ? 16 : s.depth) : 1;
                unsigned faces = s.cubemap ? 6 : 1;
                NSUInteger faceBytes = 0;
                for (unsigned l = 0; l < s.levels; l++)
                    faceBytes += linear ?
                                     s.pitch * h :
                                     (NSUInteger)MAX(1u, w >> l) *
                                         MAX(1u, h >> l) * MAX(1u, d >> l) * 2;
                NSUInteger stride = s.cubemap ?
                                        (faceBytes + 127) & ~(NSUInteger)127 :
                                        faceBytes;
                NSMutableData *seed =
                    [NSMutableData dataWithLength:3 + faces * stride + 7];
                memset(seed.mutableBytes, 0x5a, seed.length);
                uint8_t *bytes = seed.mutableBytes;
                for (unsigned f = 0; f < faces; f++) {
                    NSUInteger base = 3 + f * stride;
                    for (unsigned l = 0; l < s.levels; l++) {
                        unsigned lw = MAX(1u, w >> l), lh = MAX(1u, h >> l),
                                 ld = MAX(1u, d >> l);
                        for (unsigned z = 0; z < ld; z++)
                            for (unsigned y = 0; y < lh; y++)
                                for (unsigned x = 0; x < lw; x++) {
                                    unsigned value = ((f * 37 + l * 19 +
                                                       z * 71 + y * 11 + x) *
                                                          40503 +
                                                      0x1289) &
                                                     65535;
                                    NSUInteger at =
                                        base +
                                        (linear ?
                                             y * s.pitch + x * 2 :
                                             morton(x, y, z, lw, lh, ld) * 2);
                                    bytes[at] = value;
                                    bytes[at + 1] = value >> 8;
                                }
                        base += linear ? s.pitch * lh :
                                         (NSUInteger)lw * lh * ld * 2;
                    }
                }
                require([commands beginWithError:&error] != nil, error);
                id<MTLBuffer> source = lane_private_source(seed);
                NV2AMetalTextureUploadResult *r = upload(s, source, 3, nil, 0);
                LaneCase c = { s.format, 0, 9, 2, linear };
                id<MTLTexture> reference = lane_float_decoder(s, c, source, 3);
                assert(r.texture.pixelFormat ==
                           (family == 0 ? MTLPixelFormatB5G6R5Unorm :
                            family == 3 ? MTLPixelFormatABGR4Unorm :
                                          MTLPixelFormatBGR5A1Unorm) &&
                       r.sourceLength == faces * stride &&
                       r.texture.width == w && r.texture.height == h &&
                       r.texture.depth == d);
                NSMutableArray *actual = [NSMutableArray new],
                               *old = [NSMutableArray new];
                for (unsigned f = 0; f < faces; f++)
                    for (unsigned l = 0; l < s.levels; l++) {
                        [actual addObject:read_texture(r.texture, l, f)];
                        [old addObject:read_texture(reference, l, f)];
                    }
                finish();
                assert(!*(uint32_t *)r.faults.contents);
                for (unsigned i = 0; i < actual.count; i++) {
                    id<MTLBuffer> a = actual[i], b = old[i];
                    assert(a.length == b.length);
                    unsigned l = i % s.levels;
                    unsigned lw = MAX(1u, w >> l), lh = MAX(1u, h >> l),
                             ld = MAX(1u, d >> l);
                    NSUInteger row = (lw * 16 + 255) & ~(NSUInteger)255;
                    assert(a.length == row * lh * ld);
                    for (unsigned z = 0; z < ld; z++)
                        for (unsigned y = 0; y < lh; y++)
                            lane_compare((const uint8_t *)a.contents +
                                             (z * lh + y) * row,
                                         (const uint8_t *)b.contents +
                                             (z * lh + y) * row,
                                         lw * 16, "packed decode");
                }
                NSData *wire =
                    nv2a_metal_texture_snapshot(r.texture, commands, &error);
                require(wire != nil, error);
                assert(lane_be(wire.bytes) == 0x4d345458 &&
                       lane_be((const uint8_t *)wire.bytes + 4) == 2 &&
                       lane_be((const uint8_t *)wire.bytes + 36) ==
                           (family ? 9 + family : 9));
                NSUInteger pos = 40;
                for (unsigned f = 0; f < faces; f++) {
                    NSUInteger base = 3 + f * stride;
                    for (unsigned l = 0; l < s.levels; l++) {
                        unsigned lw = MAX(1u, w >> l), lh = MAX(1u, h >> l),
                                 ld = MAX(1u, d >> l);
                        for (unsigned z = 0; z < ld; z++)
                            for (unsigned y = 0; y < lh; y++)
                                for (unsigned x = 0; x < lw; x++) {
                                    NSUInteger at =
                                        base +
                                        (linear ?
                                             y * s.pitch + x * 2 :
                                             morton(x, y, z, lw, lh, ld) * 2);
                                    const uint8_t *payload = wire.bytes;
                                    assert(payload[pos] == bytes[at + 1] &&
                                           payload[pos + 1] == bytes[at]);
                                    pos += 2;
                                    texels++;
                                }
                        subresources++;
                        base += linear ? s.pitch * lh :
                                         (NSUInteger)lw * lh * ld * 2;
                    }
                }
                assert(pos == wire.length);
                id<MTLTexture> restored =
                    nv2a_metal_texture_restore(wire, commands, &error);
                require(restored != nil, error);
                assert([nv2a_metal_texture_snapshot(restored, commands, &error)
                    isEqualToData:wire]);
                lane_filters(r.texture, restored, reference);
                if (s.levels > 1) {
                    NSRange levels = NSMakeRange(1, s.levels - 1),
                            slices = NSMakeRange(0, faces);
                    id<MTLTexture> view = [r.texture
                        newTextureViewWithPixelFormat:r.texture.pixelFormat
                                          textureType:r.texture.textureType
                                               levels:levels
                                               slices:slices];
                    id<MTLTexture> oldView = [reference
                        newTextureViewWithPixelFormat:reference.pixelFormat
                                          textureType:reference.textureType
                                               levels:levels
                                               slices:slices];
                    assert(view && oldView);
                    NSData *viewWire =
                        nv2a_metal_texture_snapshot(view, commands, &error);
                    require(viewWire != nil, error);
                    id<MTLTexture> viewRestore =
                        nv2a_metal_texture_restore(viewWire, commands, &error);
                    require(viewRestore != nil, error);
                    lane_filters(view, viewRestore, oldView);
                }
            }
        }
    printf("Packed16:4 formats/32 layouts/%u subresources/%u exact texels/BE16 "
           "snapshot bytes,"
           "private producer,offset3/pitch/mips/2D/3D/cube/border/1x1;"
           "%u bit-exact manual nearest/linear/mip/aniso/border/view/restore "
           "pairs PASS\n",
           subresources, texels, lane_sample_pairs - filterPairs);
}
#endif
