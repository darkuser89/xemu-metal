/* Base-only manual sampling versus the original derivative implementation.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SAMPLER_BASE_ONLY_H
#define TEST_METAL_SAMPLER_BASE_ONLY_H
#include "test-metal-sampling-reference.h"
#define metal_shader_source bs_source
#include "pixel-shader-source.h"
#undef metal_shader_source

typedef struct {
    NV2AMetalSamplingUniforms sampling;
    unsigned half_mask;
    float logical[2], inverse[2];
} BSPacket;
_Static_assert(sizeof(BSPacket) == 72, "base sampler CPU/MSL packet");

static id<MTLLibrary> bs_library(id<MTL4Compiler> compiler, BOOL reference)
{
    NSError *error = nil;
    NSString *source = @(bs_source);
    if (reference)
        source = sampling_force_gradients(source);
    source = [source
        stringByAppendingString:
            @"\nstruct BSPacket{NV2AMetalSamplingUniforms sampling;uint "
            @"half_mask;"
             "float logical[2],inverse[2];};"
             "struct BSVertex{float4 p [[position]];};"
             "vertex BSVertex bs_vertex(uint i [[vertex_id]]){"
             "const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};"
             "BSVertex o;o.p=float4(p[i],0,1);return o;}"
             "static float4 bs_coord(BSVertex v,device const float4*c){"
             "uint2 p=min(uint2(v.p.xy),uint2(7));return c[p.y*8+p.x];}"
             "fragment float4 bs_2d(BSVertex v [[stage_in]],"
             "constant BSPacket&p [[buffer(0)]],device const float4*c "
             "[[buffer(1)]],"
             "texture2d<float>t [[texture(0)]],sampler s [[sampler(0)]]){"
             "return nv2a_sample(t,s,bs_coord(v,c).xy,p.sampling,p.half_mask);}"
             "fragment float4 bs_3d(BSVertex v [[stage_in]],"
             "constant BSPacket&p [[buffer(0)]],device const float4*c "
             "[[buffer(1)]],"
             "texture3d<float>t [[texture(0)]],sampler s [[sampler(0)]]){"
             "return "
             "nv2a_sample(t,s,bs_coord(v,c).xyz,p.sampling,p.half_mask);}"
             "fragment float4 bs_cube(BSVertex v [[stage_in]],"
             "constant BSPacket&p [[buffer(0)]],device const float4*c "
             "[[buffer(1)]],"
             "texturecube<float>t [[texture(0)]],sampler s [[sampler(0)]]){"
             "return nv2a_sample(t,s,bs_coord(v,c).xyz,p.sampling,"
             "float2(p.logical[0],p.logical[1]),float2(p.inverse[0],p.inverse["
             "1]),"
             "p.half_mask);}\n"];
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = source;
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    ld.options.mathMode = MTLMathModeSafe;
    ld.options.mathFloatingPointFunctions =
        MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> result = [compiler newLibraryWithDescriptor:ld error:&error];
    require(result != nil, error);
    return result;
}

static id<MTLTexture> bs_texture(id<MTLDevice> device, unsigned type,
                                 BOOL special)
{
    unsigned size = type == 2 ? 16 : 8;
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:size
                                    height:size
                                 mipmapped:YES];
    d.textureType = type == 0 ? MTLTextureType2D :
                    type == 1 ? MTLTextureType3D :
                                MTLTextureTypeCube;
    d.depth = type == 1 ? 4 : 1;
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [device newTextureWithDescriptor:d];
    assert(t);
    const uint32_t bits[] = { 0,          0x80000000, 1,          0x80000001,
                              0x7f800000, 0xff800000, 0x7fc00005, 0x7f7fffff };
    for (unsigned face = 0; face < (type == 2 ? 6u : 1u); face++)
        for (unsigned level = 0; level < t.mipmapLevelCount; level++) {
            unsigned n = MAX(1u, size >> level),
                     depth = type == 1 ? MAX(1u, 4u >> level) : 1;
            float data[16 * 16 * 4 * 4];
            for (unsigned z = 0; z < depth; z++)
                for (unsigned y = 0; y < n; y++)
                    for (unsigned x = 0; x < n; x++)
                        for (unsigned k = 0; k < 4; k++) {
                            unsigned i = 4 * ((z * n + y) * n + x) + k;
                            data[i] = ((x * 37 + y * 11 + z * 7 + face * 19 +
                                        k * 5 + level * 23) %
                                       256) /
                                      256.f;
                            if (special &&
                                (x + y + z + face + level) % 3 == 0) {
                                uint32_t b = bits[(x + y + z + k) % 8];
                                memcpy(&data[i], &b, 4);
                            }
                        }
            [t replaceRegion:MTLRegionMake3D(0, 0, 0, n, n, depth)
                  mipmapLevel:level
                        slice:face
                    withBytes:data
                  bytesPerRow:n * 16
                bytesPerImage:n * n * 16];
        }
    return t;
}

static void bs_coordinates(float c[64][4], unsigned type, unsigned pattern)
{
    const uint32_t bits[] = { 0,          0x80000000, 1,          0x80000001,
                              0x00800000, 0x7f7fffff, 0xff7fffff, 0x7f800000,
                              0xff800000, 0x7fc00005, 0x3effffff, 0x3f000001,
                              0x3f800000, 0xbf800000, 0x4b800001, 0xcb800001 };
    const float edges[] = { -.0001f, 0,          .0625f, .49999997f,
                            .5f,     .50000006f, 1,      1.0001f };
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            unsigned i = y * 8 + x;
            c[i][0] = .5f + (x - 3.5f) * (pattern == 1 ? 1.25f : .125f);
            c[i][1] = .5f + (y - 3.5f) * (pattern == 1 ? .03125f : .125f);
            c[i][2] = .4f + ((float)x - (float)y) * .0625f;
            c[i][3] = 1;
            if (pattern == 2) {
                for (unsigned k = 0; k < 3; k++) {
                    uint32_t b = bits[(i + k * 5) % 16];
                    memcpy(&c[i][k], &b, 4);
                }
            } else if (pattern == 3) {
                c[i][0] = edges[x];
                c[i][1] = edges[7 - y];
                c[i][2] = edges[(x + y) % 8];
                if (type == 2) {
                    unsigned face = (x / 2 + 4 * (y / 2)) % 6, axis = face / 2;
                    c[i][axis] = face & 1 ? -1 : 1;
                    c[i][(axis + 1) % 3] = (x & 1) ? 1.0001f : .9999f;
                    c[i][(axis + 2) % 3] = (y & 1) ? -1 : 1;
                }
            }
        }
}

static void bs_pair(NV2AMetalCommands *commands,
                    id<MTL4ArgumentTable> arguments,
                    id<MTLRenderPipelineState> const pipelines[2],
                    id<MTLTexture> texture, id<MTLSamplerState> sampler,
                    id<MTLTexture> target, BSPacket packet, unsigned type,
                    unsigned pattern, unsigned ordinal)
{
    NSError *error = nil;
    float c[64][4];
    bs_coordinates(c, type, pattern);
    id<MTLBuffer> coords =
        [commands.device newBufferWithBytes:c
                                     length:sizeof(c)
                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> uniforms =
        [commands.device newBufferWithBytes:&packet
                                     length:sizeof(packet)
                                    options:MTLResourceStorageModeShared];
    require(coords && uniforms && [commands beginWithError:&error], error);
    for (id r in @[ coords, uniforms, texture, target ])
        require([commands addResource:r error:&error], error);
    require([commands keepAlive:arguments error:&error] &&
                [commands keepAlive:sampler error:&error],
            error);
    [arguments setAddress:uniforms.gpuAddress atIndex:0];
    [arguments setAddress:coords.gpuAddress atIndex:1];
    [arguments setTexture:texture.gpuResourceID atIndex:0];
    [arguments setSamplerState:sampler.gpuResourceID atIndex:0];
    id<MTLBuffer> output[2];
    for (unsigned selected = 0; selected < 2; selected++) {
        require([commands keepAlive:pipelines[selected] error:&error], error);
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(7, 11, 13, 17);
        id<MTL4RenderCommandEncoder> e =
            [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
        assert(e);
        [e barrierAfterQueueStages:MTLStageAll
                      beforeStages:MTLStageAll
                 visibilityOptions:MTL4VisibilityOptionDevice];
        [e setArgumentTable:arguments atStages:MTLRenderStageFragment];
        [e setRenderPipelineState:pipelines[selected]];
        [e setViewport:(MTLViewport){ 0, 0, 8, 8, 0, 1 }];
        [e setCullMode:MTLCullModeNone];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e barrierAfterStages:MTLStageAll
            beforeQueueStages:MTLStageAll
            visibilityOptions:MTL4VisibilityOptionDevice];
        [e endEncoding];
        output[selected] = ck_read(commands, target);
    }
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    const float sentinel[4] = { 7, 11, 13, 17 };
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            const uint8_t *a =
                (const uint8_t *)output[0].contents + y * 256 + x * 16;
            const uint8_t *b =
                (const uint8_t *)output[1].contents + y * 256 + x * 16;
            if (memcmp(a, b, 16) || !memcmp(a, sentinel, 16)) {
                fprintf(
                    stderr,
                    "Base sampler case%u type%u pattern%u pixel%u,%u differs\n",
                    ordinal, type, pattern, x, y);
                abort();
            }
        }
}

static void sampler_base_only_tests(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    id<MTLLibrary> libraries[2] = { bs_library(compiler, NO),
                                    bs_library(compiler, YES) };
    id<MTLRenderPipelineState> pipelines[3][2];
    NSArray *names = @[ @"bs_2d", @"bs_3d", @"bs_cube" ];
    for (unsigned type = 0; type < 3; type++)
        for (unsigned side = 0; side < 2; side++) {
            MTL4LibraryFunctionDescriptor *v = [MTL4LibraryFunctionDescriptor
                                              new],
                                          *f = [MTL4LibraryFunctionDescriptor
                                              new];
            v.library = f.library = libraries[side];
            v.name = @"bs_vertex";
            f.name = names[type];
            MTL4RenderPipelineDescriptor *d =
                [MTL4RenderPipelineDescriptor new];
            d.vertexFunctionDescriptor = v;
            d.fragmentFunctionDescriptor = f;
            d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
            d.rasterSampleCount = 1;
            pipelines[type][side] =
                [compiler newRenderPipelineStateWithDescriptor:d
                                           compilerTaskOptions:nil
                                                         error:&error];
            require(pipelines[type][side] != nil, error);
        }
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 2;
    ad.maxTextureBindCount = 1;
    ad.maxSamplerStateBindCount = 1;
    ad.initializeBindings = YES;
    id<MTL4ArgumentTable> arguments =
        [commands.device newArgumentTableWithDescriptor:ad error:&error];
    require(arguments != nil, error);
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.supportArgumentBuffers = YES;
    sd.sAddressMode = sd.tAddressMode = sd.rAddressMode =
        MTLSamplerAddressModeClampToEdge;
    sd.mipFilter = MTLSamplerMipFilterNearest;
    id<MTLSamplerState> sampler =
        [commands.device newSamplerStateWithDescriptor:sd];
    assert(sampler);
    id<MTLTexture> target =
        attachment(commands.device, MTLPixelFormatRGBA32Float, 1);
    unsigned cases = 0;
    for (unsigned type = 0; type < 3; type++) {
        id<MTLTexture> textures[2] = { bs_texture(commands.device, type, NO),
                                       bs_texture(commands.device, type, YES) };
        for (unsigned linear = 0; linear < 2; linear++)
            for (unsigned address = 1; address <= 5; address++)
                for (unsigned bias = 0; bias < 3; bias++)
                    for (unsigned variant = 0; variant < 4; variant++)
                        for (unsigned pattern = 0; pattern < 4; pattern++)
                            for (unsigned border = 0;
                                 border < (type == 2 ? 2u : 1u); border++)
                                @autoreleasepool {
                                    BSPacket p = {
                                        .sampling = { .enabled = 1,
                                                      .address = { address,
                                                                   address,
                                                                   address },
                                                      .min_linear = linear,
                                                      .mag_linear = linear,
                                                      .anisotropy = 1,
                                                      .lod_bias =
                                                          (float[]){
                                                              -16, 0,
                                                              4095.f /
                                                                  256 }[bias],
                                                      .border_color = { -0.f,
                                                                        .125f,
                                                                        .25f,
                                                                        1 } },
                                        .half_mask =
                                            (unsigned[]){ 0, 5, 15, 0 }[variant]
                                    };
                                    if (border) {
                                        p.logical[0] = p.logical[1] = 8;
                                        p.inverse[0] = p.inverse[1] = 1.f / 16;
                                    }
                                    bs_pair(commands, arguments,
                                            pipelines[type],
                                            textures[variant == 3], sampler,
                                            target, p, type, pattern, cases++);
                                }
        for (unsigned control = 0; control < 8; control++)
            for (unsigned linear = 0; linear < 2; linear++)
                for (unsigned pattern = 0; pattern < 4; pattern++)
                    if (pattern != 2)
                        @autoreleasepool {
                            BSPacket p = { .sampling = { .enabled =
                                                             control ? 1u : 0u,
                                                         .address = { 3, 3, 3 },
                                                         .min_linear = linear,
                                                         .mag_linear = linear,
                                                         .anisotropy = 1 } };
                            if (control == 1 || control == 2)
                                p.sampling.mip_filter = control;
                            if (control == 3) {
                                p.sampling.min_linear = 1;
                                p.sampling.mag_linear = 0;
                            }
                            if (control == 4) {
                                p.sampling.min_linear = 0;
                                p.sampling.mag_linear = 1;
                            }
                            if (control >= 5)
                                p.sampling.anisotropy = 1u << (control - 4);
                            bs_pair(commands, arguments, pipelines[type],
                                    textures[0], sampler, target, p, type,
                                    pattern, cases++);
                        }
    }
    assert(cases == 2064);
    printf("Base-only sampling:2064 exact optimized/original Float4 image "
           "pairs/132096 pixels;2D/3D/cube,nearest/linear,all5 addresses,bias "
           "limits,half masks,signed "
           "zero/NaN/Inf/subnormals,overflow,seams/physical borders;144 "
           "mip/AF/min-mag/native controls PASS\n");
}
#endif
