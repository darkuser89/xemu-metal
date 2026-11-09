/* DstAlpha on Xbox X surfaces, with variable A7 and native-alpha controls.
 * SPDX-License-Identifier: LGPL-2.0-or-later
 * Test: abaire/nxdk_pgraph_tests, de548172ac3166f03f3a75999829ba17aade73aa,
 * src/tests/blend_surface_tests.cpp, TestDstAlpha.
 * Golden RGB swatches: nxdk_pgraph_tests_golden_results/results/Blend_surface.
 * X_ZRGB8 DstAlpha blob cac4201412f5b33035bf98d10698429fe257c0e2;
 * A7_Z DstAlpha blob de0534e9b27b003b6ed6621804670e8bc1b4fcc4.
 */
#ifndef TEST_METAL_DSTALPHA_SURFACES_H
#define TEST_METAL_DSTALPHA_SURFACES_H
/* Independent ordered-UNORM oracle for the existing host dither policy. */
static unsigned dstalpha_quantize(double value, unsigned bits, unsigned pixel)
{
    unsigned x = pixel % 16, y = pixel / 16, rank = 0;
    for (unsigned b = 0; b < 2; b++) {
        unsigned xx = (x >> b) & 1, yy = (y >> b) & 1;
        rank += (2 * (xx ^ yy) + yy) << (2 * (1 - b));
    }
    double scaled = value * ((1u << bits) - 1);
    return (unsigned)floor(scaled) +
           (scaled - floor(scaled) >= (rank + .5) / 16.0);
}

static void dstalpha_surface_tests(void)
{
    const struct {
        MTLPixelFormat format;
        unsigned policy, bytes, bits[4], shift[4];
    } formats[] = {
        {MTLPixelFormatBGR5A1Unorm,
         NV2AMetalSurfaceStorageZ1,
         2,
         {5, 5, 5, 1},
         {10, 5, 0, 15}},
        {MTLPixelFormatBGR5A1Unorm,
         NV2AMetalSurfaceStorageO1,
         2,
         {5, 5, 5, 1},
         {10, 5, 0, 15}},
        {MTLPixelFormatBGRA8Unorm,
         NV2AMetalSurfaceStorageZ8,
         4,
         {8, 8, 8, 8},
         {16, 8, 0, 24}},
        {MTLPixelFormatBGRA8Unorm,
         NV2AMetalSurfaceStorageO8,
         4,
         {8, 8, 8, 8},
         {16, 8, 0, 24}},
        {MTLPixelFormatBGRA8Unorm,
         NV2AMetalSurfaceStorageZ7,
         4,
         {8, 8, 8, 8},
         {16, 8, 0, 24}},
        {MTLPixelFormatBGRA8Unorm,
         NV2AMetalSurfaceStorageO7,
         4,
         {8, 8, 8, 8},
         {16, 8, 0, 24}},
        {MTLPixelFormatBGRA8Unorm,
         NV2AMetalSurfaceStorageNative,
         4,
         {8, 8, 8, 8},
         {16, 8, 0, 24}},
        {MTLPixelFormatBGR5A1Unorm,
         NV2AMetalSurfaceStorageNative,
         2,
         {5, 5, 5, 1},
         {10, 5, 0, 15}},
        {MTLPixelFormatB5G6R5Unorm,
         NV2AMetalSurfaceStorageNative,
         2,
         {5, 6, 5, 0},
         {11, 5, 0, 0}},
    };
    NSError *error = nil;
    NV2AMetalVertex v[6];
    quad(v);
    for (unsigned i = 0; i < 6; i++) {
        for (unsigned c = 0; c < 3; c++)
            v[i].color[0][c] = 1;
        v[i].color[0][3] = 34.f / 255;
    }
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    assert(input);
    unsigned cases = 0;
    for (unsigned f = 0; f < 9; f++) {
        unsigned policy = formats[f].policy;
        BOOL opaque = policy >= NV2AMetalSurfaceStorageZ1 &&
                      policy <= NV2AMetalSurfaceStorageO8;
        BOOL a7 = policy >= NV2AMetalSurfaceStorageZ7;
        NV2AMetalPixelShader *pipeline =
            [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                             colorFormat:formats[f].format
                                             depthFormat:MTLPixelFormatInvalid
                                             sampleCount:1
                                         surfaceChannels:policy
                                                   error:&error];
        require(pipeline != nil, error);
        MTLTextureDescriptor *d = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:formats[f].format
                                         width:16
                                        height:16
                                     mipmapped:NO];
        d.storageMode = MTLStorageModeShared;
        d.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> target = [commands.device newTextureWithDescriptor:d];
        assert(target);
        uint8_t seed[1024] = {0}, result[1024];
        uint32_t initial[256];
        unsigned max[4];
        for (unsigned c = 0; c < 4; c++)
            max[c] = (1u << formats[f].bits[c]) - 1;
        for (unsigned i = 0; i < 256; i++) {
            initial[i] = ((i & max[3]) << formats[f].shift[3]);
            for (unsigned c = 0; c < 3; c++)
                initial[i] |= ((17u + c * 37) & max[c]) << formats[f].shift[c];
            memcpy(seed + i * formats[f].bytes, initial + i, formats[f].bytes);
        }
        for (unsigned destination = 0; destination < 2; destination++)
            for (unsigned inverse = 0; inverse < 2; inverse++)
                for (unsigned dither = 0; dither < 2; dither++)
                    for (unsigned mask = 0; mask < 4; mask++) {
                        NV2AMetalDrawConfig config = draw_config();
                        if (mask == 1)
                            config.control[0] &=
                                ~NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
                        if (mask == 2)
                            config.control[0] =
                                NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
                        if (mask == 3)
                            config.control[0] = 0;
                        if (dither)
                            config.control[0] |=
                                NV_PGRAPH_CONTROL_0_DITHERENABLE;
                        config.blend = NV_PGRAPH_BLEND_EN | 2 |
                                       (6u + inverse) << (destination ? 8 : 4);
                        NV2AMetalDrawState *state = [[NV2AMetalDrawState alloc]
                            initWithDevice:commands.device
                                    config:&config
                                     error:&error];
                        require(state != nil, error);
                        [target replaceRegion:MTLRegionMake2D(0, 0, 16, 16)
                                  mipmapLevel:0
                                    withBytes:seed
                                  bytesPerRow:16 * formats[f].bytes];
                        MTL4RenderPassDescriptor *pass =
                            [MTL4RenderPassDescriptor new];
                        pass.colorAttachments[0].texture = target;
                        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
                        pass.colorAttachments[0].storeAction =
                            MTLStoreActionStore;
                        NV2AMetalPixelUniforms u = uniforms();
                        u.clip_regions[0][2] = u.clip_regions[0][3] = 16;
                        NV2AMetalPixelTexture textures[4] = {0};
                        require([commands beginWithError:&error] != nil, error);
                        require([pipeline
                                    encodeVertices:input
                                             count:6
                                         primitive:MTLPrimitiveTypeTriangle
                                          uniforms:&u
                                          textures:textures
                                              pass:pass
                                         drawState:state
                                          commands:commands
                                             error:&error],
                                error);
                        require([commands submitWithError:&error] &&
                                    [commands waitUntilIdleWithError:&error],
                                error);
                        [target getBytes:result
                             bytesPerRow:16 * formats[f].bytes
                              fromRegion:MTLRegionMake2D(0, 0, 16, 16)
                             mipmapLevel:0];
                        for (unsigned i = 0; i < 256; i++) {
                            double alpha = opaque || !max[3] ? 1
                                           : a7 ? (i & 127) / 127.0
                                                : (i & max[3]) / (double)max[3];
                            double factor = inverse ? 1 - alpha : alpha;
                            uint32_t actual = 0;
                            memcpy(&actual, result + i * formats[f].bytes,
                                   formats[f].bytes);
                            for (unsigned c = 0; c < 4; c++) {
                                if (!max[c])
                                    continue;
                                unsigned old =
                                    (initial[i] >> formats[f].shift[c]) &
                                    max[c];
                                BOOL write =
                                    c == 3 ? mask == 0 || mask == 2 : mask < 2;
                                double value = destination
                                                   ? c == 3 && a7
                                                         ? (i & 127) / 127.0
                                                         : old / (double)max[c]
                                               : c == 3 ? 34.0 / 255
                                                        : 1;
                                double expected =
                                    write ? value * factor * max[c] : old;
                                if (write && dither)
                                    expected = dstalpha_quantize(
                                        value * factor, formats[f].bits[c], i);
                                if (write && c == 3 && opaque)
                                    expected =
                                        policy == NV2AMetalSurfaceStorageO1 ||
                                                policy ==
                                                    NV2AMetalSurfaceStorageO8
                                            ? max[c]
                                            : 0;
                                if (write && c == 3 && a7) {
                                    unsigned code =
                                        dither ? dstalpha_quantize(
                                                     value * factor, 7, i)
                                               : (unsigned)floor(
                                                     value * factor * 127 + .5);
                                    expected =
                                        code |
                                        (policy == NV2AMetalSurfaceStorageO7
                                             ? 128u
                                             : 0u);
                                }
                                unsigned got =
                                    (actual >> formats[f].shift[c]) & max[c];
                                if (fabs(got - expected) > .51) {
                                    fprintf(
                                        stderr,
                                        "DstAlpha surface%u raw%u dest%u inv%u "
                                        "dither%u mask%u channel%u got%u "
                                        "expected%.9f\n",
                                        f, i, destination, inverse, dither,
                                        mask, c, got, expected);
                                    abort();
                                }
                            }
                            /* Lower-half RGB values read from the pinned Xbox
                             * images. */
                            if (!destination && !dither && mask == 0 &&
                                f <= 6) {
                                const unsigned codes[] = {0, 64, 128, 255};
                                const unsigned a7codes[] = {0, 32, 64, 127};
                                const unsigned a7white[] = {0, 64, 129, 255};
                                const unsigned a7inverse[] = {255, 191, 126, 0};
                                for (unsigned k = 0; k < 4; k++)
                                    if (i == (a7 ? a7codes[k] : codes[k])) {
                                        unsigned expected =
                                            opaque    ? inverse ? 0 : 255
                                            : a7      ? inverse ? a7inverse[k]
                                                                : a7white[k]
                                            : inverse ? 255 - codes[k]
                                                      : codes[k];
                                        unsigned blue = actual & max[2];
                                        assert(blue ==
                                               (formats[f].bytes == 2
                                                    ? (expected ? 31u : 0u)
                                                    : expected));
                                    }
                            }
                        }
                        draws++;
                        cases++;
                    }
    }
    assert(cases == 288);
    puts("DstAlpha surfaces:288 GPU draws/73728 pixels, all256 stored alpha "
         "bytes, "
         "source/destination factors,complements,dither,4 write masks;X1/X8 "
         "opaque,"
         "A7/native-alpha controls and pinned Xbox RGB swatches PASS");
}
#endif
