/* Block-wise BC transport versus the original per-texel GPU decoder.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_BC_BLOCK_UPLOAD_H
#define TEST_METAL_BC_BLOCK_UPLOAD_H
@interface NV2AMetalTextureUpload (BCBlockTest)
- (BOOL)canDecodeBCBlocksForShape:(const NV2AMetalTextureShape *)shape;
- (BOOL)prepareBlockDecoderWithError:(NSError **)error;
@end
@interface BCBlockReference : NV2AMetalTextureUpload
@end
@implementation BCBlockReference
- (BOOL)canDecodeBCBlocksForShape:(const NV2AMetalTextureShape *)shape
{
    (void)shape;
    return NO; /* Exact old layout, storage, kernel and per-texel dispatch. */
}
@end
static const unsigned bcu_formats[] = {
    NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT1_A1R5G5B5,
    NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT23_A8R8G8B8,
    NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT45_A8R8G8B8
};
static _Thread_local BOOL bcu_scope, bcu_preparing, bcu_late_fail;
static _Thread_local unsigned bcu_fail_function, bcu_fail_table;
static _Thread_local NSUInteger bcu_dispatches, bcu_threads, bcu_encoders;
static NSError *bcu_failure;
static void (*bcu_dispatch_original)(id, SEL, MTLSize, MTLSize);
static id (*bcu_encoder_original)(id, SEL);
static void bcu_dispatch(id owner, SEL selector, MTLSize size, MTLSize group)
{
    if (bcu_scope) {
        bcu_dispatches++;
        bcu_threads += size.width * size.height * size.depth;
    }
    bcu_dispatch_original(owner, selector, size, group);
}
static id bcu_encoder(id owner, SEL selector)
{
    if (bcu_scope)
        bcu_encoders++;
    return bcu_encoder_original(owner, selector);
}
static id (*bcu_function_original)(id, SEL, NSString *, NSError **);
static id bcu_function(id owner, SEL selector, NSString *name, NSError **error)
{
    if (bcu_preparing && bcu_fail_function &&
        [name isEqualToString:@"nv2a_texture_decode_bc_blocks"]) {
        bcu_fail_function--;
        if (error)
            *error = bcu_failure;
        return nil;
    }
    return bcu_function_original(owner, selector, name, error);
}
/* A typed new-family category keeps ARC ownership identical to the device API.
 */
@interface NSObject (BCBlockArgumentFactory)
- (id<MTL4ArgumentTable>)bcu_newArgumentTableWithDescriptor:
                             (MTL4ArgumentTableDescriptor *)d
                                                      error:(NSError **)error
    __attribute__((objc_method_family(new)));
@end
@implementation NSObject (BCBlockArgumentFactory)
- (id<MTL4ArgumentTable>)bcu_newArgumentTableWithDescriptor:
                             (MTL4ArgumentTableDescriptor *)d
                                                      error:(NSError **)error
{
    if (bcu_preparing && bcu_fail_table && d.maxBufferBindCount == 5) {
        bcu_fail_table--;
        if (error)
            *error = bcu_failure;
        return nil;
    }
    return [self bcu_newArgumentTableWithDescriptor:d error:error];
}
@end
static unsigned bcu_profile(unsigned face, unsigned level, unsigned bx,
                            unsigned by, unsigned z, unsigned phase)
{
    return (face * 3 + (face >> 2) + level + bx + by * 2 + z + (z >> 2) +
            phase) %
           4;
}
/* Literal endpoint/palette witnesses, rather than another BC decoder. Profiles
 * include c0<c1, c0==c1 and non-divisible low RGB565 interpolation values. */
static const uint16_t bcu_endpoints[4][2] = { { 0xf800, 0x07e0 },
                                              { 0x0000, 0xffff },
                                              { 0x0841, 0x0841 },
                                              { 0x1863, 0x0841 } };
static const uint8_t bcu_rgb[4][4][3] = {
    { { 255, 0, 0 }, { 0, 255, 0 }, { 170, 85, 0 }, { 85, 170, 0 } },
    { { 0, 0, 0 }, { 255, 255, 255 }, { 85, 85, 85 }, { 170, 170, 170 } },
    { { 8, 8, 8 }, { 8, 8, 8 }, { 8, 8, 8 }, { 8, 8, 8 } },
    { { 24, 12, 24 }, { 8, 8, 8 }, { 18, 10, 18 }, { 13, 9, 13 } }
};
static const uint8_t bcu_alpha4[16] = {
    0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255
};
static const uint8_t bcu_alpha8[3][8] = {
    { 203, 61, 182, 162, 142, 121, 101, 81 },
    { 61, 203, 89, 117, 146, 174, 0, 255 },
    { 113, 113, 113, 113, 113, 113, 0, 255 }
};
static void bcu_block(uint8_t *p, unsigned format, unsigned profile,
                      unsigned phase)
{
    unsigned color = format ? 8 : 0;
    for (unsigned c = 0; c < 2; c++) {
        uint16_t word = bcu_endpoints[profile][c];
        p[color + c * 2] = word;
        p[color + c * 2 + 1] = word >> 8;
    }
    uint32_t selectors = 0;
    uint64_t alpha = 0;
    for (unsigned i = 0; i < 16; i++) {
        selectors |= ((i + phase) % 4) << (2 * i);
        if (format == 1)
            p[i / 2] |= ((i + phase) % 16) << (4 * (i % 2));
        if (format == 2)
            alpha |= (uint64_t)((i + phase) % 8) << (3 * i);
    }
    for (unsigned i = 0; i < 4; i++)
        p[color + 4 + i] = selectors >> (8 * i);
    if (format == 2) {
        p[0] = bcu_alpha8[phase % 3][0];
        p[1] = bcu_alpha8[phase % 3][1];
        for (unsigned i = 0; i < 6; i++)
            p[2 + i] = alpha >> (8 * i);
    }
}
static void bcu_expected(uint8_t out[4], unsigned format, unsigned profile,
                         unsigned phase, unsigned pixel)
{
    unsigned index = (pixel + phase) % 4;
    memcpy(out, bcu_rgb[profile][index], 3);
    out[3] = 255;
    if (!format && (profile == 1 || profile == 2)) {
        static const uint8_t transparent[4] = { 0, 255, 127, 0 };
        if (profile == 1)
            out[0] = out[1] = out[2] = transparent[index];
        else if (index == 3)
            out[0] = out[1] = out[2] = 0;
        if (index == 3)
            out[3] = 0;
    } else if (format == 1)
        out[3] = bcu_alpha4[(pixel + phase) % 16];
    else if (format == 2)
        out[3] = bcu_alpha8[phase % 3][(pixel + phase) % 8];
}
static void bcu_dimensions(NV2AMetalTextureShape s, unsigned *w, unsigned *h,
                           unsigned *d)
{
    *w = s.border ? MAX(16u, s.width * 2) : s.width;
    *h = s.border ? MAX(16u, s.height * 2) : s.height;
    *d = s.dimension == 3 ? (s.border ? MAX(16u, s.depth * 2) : s.depth) : 1;
}
/* Host code only lays out compressed blocks in the documented existing
 * chunk(Z/4), blockY, blockX, sliceWithinChunk order. */
static NSData *bcu_source(NV2AMetalTextureShape s, unsigned format,
                          unsigned phase, NSMutableArray<NSData *> *goldens)
{
    unsigned w, h, d;
    bcu_dimensions(s, &w, &h, &d);
    NSUInteger faceBytes = 0, blockBytes = format ? 16 : 8;
    for (unsigned l = 0; l < s.levels; l++)
        faceBytes += (NSUInteger)((MAX(1u, w >> l) + 3) / 4) *
                     ((MAX(1u, h >> l) + 3) / 4) * MAX(1u, d >> l) * blockBytes;
    NSUInteger stride =
        s.cubemap ? (faceBytes + 127) & ~(NSUInteger)127 : faceBytes;
    NSMutableData *data =
        [NSMutableData dataWithLength:3 + stride * (s.cubemap ? 6 : 1) + 7];
    memset(data.mutableBytes, 0xa7, data.length);
    for (unsigned face = 0; face < (s.cubemap ? 6u : 1u); face++) {
        NSUInteger at = 3 + face * stride;
        for (unsigned l = 0; l < s.levels; l++) {
            unsigned lw = MAX(1u, w >> l), lh = MAX(1u, h >> l),
                     ld = MAX(1u, d >> l);
            for (unsigned chunk = 0; chunk < ld; chunk += 4)
                for (unsigned by = 0; by < (lh + 3) / 4; by++)
                    for (unsigned bx = 0; bx < (lw + 3) / 4; bx++)
                        for (unsigned slice = 0; slice < MIN(4u, ld - chunk);
                             slice++) {
                            unsigned z = chunk + slice;
                            uint8_t block[16] = { 0 };
                            bcu_block(block, format,
                                      bcu_profile(face, l, bx, by, z, phase),
                                      phase + face + l + z);
                            memcpy((uint8_t *)data.mutableBytes + at, block,
                                   blockBytes);
                            at += blockBytes;
                        }
            NSMutableData *expected =
                [NSMutableData dataWithLength:(NSUInteger)lw * lh * ld * 4];
            for (unsigned z = 0; z < ld; z++)
                for (unsigned y = 0; y < lh; y++)
                    for (unsigned x = 0; x < lw; x++)
                        bcu_expected(
                            (uint8_t *)expected.mutableBytes +
                                ((z * lh + y) * lw + x) * 4,
                            format,
                            bcu_profile(face, l, x / 4, y / 4, z, phase),
                            phase + face + l + z, (y % 4) * 4 + x % 4);
            [goldens addObject:expected];
        }
        assert(at == 3 + face * stride + faceBytes);
    }
    return data;
}
static NV2AMetalTextureUploadResult *
bcu_encode(NV2AMetalTextureUpload *upload, NV2AMetalTextureShape s,
           id<MTLBuffer> source, NSUInteger offset, NSError **error)
{
    bcu_scope = YES;
    bcu_preparing = YES;
    @try {
        NV2AMetalTextureUploadResult *result = [upload encodeData:source
                                                           offset:offset
                                                          palette:nil
                                                    paletteOffset:0
                                                    paletteLength:0
                                                            shape:&s
                                                         commands:commands
                                                            error:error];
        if (result && bcu_late_fail) {
            bcu_late_fail = NO;
            if (error)
                *error = bcu_failure;
            return nil; /* Deliberate caller-boundary failure after native work.
                         */
        }
        return result;
    } @finally {
        bcu_scope = bcu_preparing = NO;
    }
}
static NSData *bcu_packed_reads(NV2AMetalTextureUploadResult *r,
                                NSMutableArray<id<MTLBuffer>> *reads)
{
    NSMutableData *bytes = [NSMutableData new];
    unsigned faces = r.texture.textureType == MTLTextureTypeCube ? 6 : 1;
    for (unsigned face = 0; face < faces; face++)
        for (unsigned l = 0; l < r.texture.mipmapLevelCount; l++) {
            unsigned w = MAX(1ul, r.texture.width >> l),
                     h = MAX(1ul, r.texture.height >> l),
                     d = MAX(1ul, r.texture.depth >> l);
            id<MTLBuffer> read = reads[face * r.texture.mipmapLevelCount + l];
            for (unsigned z = 0; z < d; z++)
                for (unsigned y = 0; y < h; y++)
                    [bytes appendBytes:pixel(read, w, h, 0, y, z)
                                length:w * 16];
        }
    return bytes;
}
static id<MTLBuffer> bcu_sample(NV2AMetalTextureUploadResult *r, BOOL border)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    NV2AMetalTextureSampler *sampler =
        [[NV2AMetalTextureSampler alloc] initWithDevice:commands.device
                                                  error:&error];
    NV2AMetalSamplerConfig config = { .filter = 1u << 16 | 1u << 24,
                                      .address = 3 | 3 << 8 | 3 << 16,
                                      .anisotropy = 1,
                                      .bordered = border };
    NV2AMetalTextureBinding *binding = [sampler bindingForTexture:r.texture
                                                           config:&config
                                                            error:&error];
    require(shader && binding, error);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:4
                                    height:4
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> target = [commands.device newTextureWithDescriptor:td];
    require(target != nil, nil);
    const float xy[6][2] = { { 0, 0 }, { 1, 0 }, { 0, 1 },
                             { 1, 0 }, { 1, 1 }, { 0, 1 } };
    NV2AMetalVertex v[6] = { 0 };
    BOOL cube = r.texture.textureType == MTLTextureTypeCube,
         volume = r.texture.textureType == MTLTextureType3D;
    for (unsigned i = 0; i < 6; i++) {
        v[i].clip[0] = xy[i][0] * 2 - 1;
        v[i].clip[1] = 1 - xy[i][1] * 2;
        v[i].clip[2] = .5f;
        v[i].clip[3] = 1;
        v[i].texcoord[0][0] = cube ? 1 : .5f;
        v[i].texcoord[0][1] = cube ? 0 : .5f;
        v[i].texcoord[0][2] = cube ? 0 : .5f;
        v[i].texcoord[0][3] = 1;
        v[i].plane[0][2] = v[i].plane[1][2] = v[i].plane[2][2] = .5f;
    }
    id<MTLBuffer> vertices = buffer(v, sizeof(v));
    NV2AMetalPixelUniforms u = { 0 };
    u.surface_scale[0] = u.surface_scale[1] = 1;
    u.clip_range[1] = u.clip_range[3] = 65535;
    u.clip_regions[0][2] = u.clip_regions[0][3] = 4;
    u.combiner.final_inputs[0] = PS_REGISTER_T0;
    u.combiner.final_inputs[1] = (PS_REGISTER_T0 | PS_CHANNEL_ALPHA) << 8;
    u.combiner.shader_stage_program = cube   ? PS_TEXTUREMODES_CUBEMAP :
                                      volume ? PS_TEXTUREMODES_PROJECT3D :
                                               PS_TEXTUREMODES_PROJECT2D;
    u.textures[0].dimension = volume ? 3 : 2;
    u.textures[0].cubemap = cube;
    u.textures[0].scale = 1;
    u.textures[0].sampling = binding.sampling;
    NV2AMetalPixelTexture textures[4] = { 0 };
    textures[0].texture = binding.texture;
    textures[0].sampler = binding.sampler;
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    require([shader encodeVertices:vertices
                             count:6
                         primitive:MTLPrimitiveTypeTriangle
                          uniforms:&u
                          textures:textures
                              pass:pass
                      depthStencil:nil
                          commands:commands
                             error:&error],
            error);
    return read_texture(target, 0, 0);
}
static NV2AMetalTextureShape bcu_shape(unsigned format, unsigned layout)
{
    NV2AMetalTextureShape s = shape(bcu_formats[format]);
    s.width = layout == 0 ? 16 : 8;
    s.height = layout == 0 ? 8 : layout == 2 ? 4 : 8;
    s.dimension = layout == 2 ? 3 : 2;
    s.depth = layout == 2 ? 8 : 1;
    s.cubemap = layout == 1;
    s.border = layout == 3;
    if (layout == 3 && format == 1)
        s.cubemap = YES;
    if (layout == 3 && format == 2) {
        s.dimension = 3;
        s.depth = 4;
    }
    s.levels = 5;
    s.max_level = 4;
    if (layout == 1 || layout == 2) {
        s.levels = 4;
        s.max_level = 3;
    }
    return s;
}
static void bcu_verify(NV2AMetalTextureUploadResult *r, NV2AMetalTextureShape s,
                       NSArray<NSData *> *goldens,
                       NSArray<id<MTLBuffer>> *reads)
{
    unsigned w, h, d;
    bcu_dimensions(s, &w, &h, &d);
    assert(r.faults.length >= 4 && !*(const uint32_t *)r.faults.contents);
    for (unsigned face = 0; face < (s.cubemap ? 6u : 1u); face++)
        for (unsigned l = 0; l < s.levels; l++) {
            unsigned lw = MAX(1u, w >> l), lh = MAX(1u, h >> l),
                     ld = MAX(1u, d >> l);
            NSData *expected = goldens[face * s.levels + l];
            const uint8_t *q = expected.bytes;
            assert(expected.length == (NSUInteger)lw * lh * ld * 4);
            for (unsigned z = 0; z < ld; z++)
                for (unsigned y = 0; y < lh; y++)
                    for (unsigned x = 0; x < lw; x++) {
                        const float *p =
                            pixel(reads[face * s.levels + l], lw, lh, x, y, z);
                        for (unsigned k = 0; k < 4; k++)
                            check(p[k],
                                  q[((z * lh + y) * lw + x) * 4 + k] / 255.f);
                    }
        }
}
static NSData *bcu_buffer_bytes(id<MTLBuffer> source);
static void bcu_pair(unsigned format, unsigned layout)
{
    NSError *error = nil;
    NV2AMetalTextureUpload *candidate =
        [[NV2AMetalTextureUpload alloc] initWithDevice:commands.device
                                                 error:&error];
    BCBlockReference *reference =
        [[BCBlockReference alloc] initWithDevice:commands.device error:&error];
    require(candidate && reference, error);
    NV2AMetalTextureShape s = bcu_shape(format, layout);
    NSMutableArray<NSData *> *goldens = [NSMutableArray new];
    NSData *sourceBytes = bcu_source(s, format, format + layout, goldens);
    require([commands beginWithError:&error] != nil, error);
    id<MTLBuffer> source = layout & 1 ?
                               lane_private_source(sourceBytes) :
                               buffer(sourceBytes.bytes, sourceBytes.length);
    NSUInteger length = 0;
    require([candidate sourceLengthForShape:&s
                              paletteLength:0
                                     length:&length
                                      error:&error] &&
                length + 10 == sourceBytes.length,
            error);
    bcu_dispatches = bcu_threads = 0;
    NV2AMetalTextureUploadResult *a =
        bcu_encode(candidate, s, source, 3, &error);
    NSUInteger blocks = bcu_threads, dispatches = bcu_dispatches;
    NV2AMetalTextureUploadResult *b =
        bcu_encode(reference, s, source, 3, &error);
    require(a && b, error);
    NSUInteger oldThreads = bcu_threads - blocks;
    NSMutableArray<id<MTLBuffer>> *ar = [NSMutableArray new],
                                  *br = [NSMutableArray new];
    for (unsigned face = 0; face < (s.cubemap ? 6u : 1u); face++)
        for (unsigned l = 0; l < s.levels; l++) {
            [ar addObject:read_texture(a.texture, l, face)];
            [br addObject:read_texture(b.texture, l, face)];
        }
    id<MTLBuffer> as = bcu_sample(a, s.border), bs = bcu_sample(b, s.border);
    finish();
    bcu_verify(a, s, goldens, ar);
    bcu_verify(b, s, goldens, br);
    if (s.cubemap)
        for (unsigned face = 0; face < 6; face++)
            for (unsigned other = 0; other < face; other++)
                assert(![goldens[face * s.levels]
                    isEqualToData:goldens[other * s.levels]]);
    if (s.dimension == 3 && !s.border && s.depth == 8) {
        NSData *base = goldens[0];
        NSUInteger sliceBytes = (NSUInteger)s.width * s.height * 4;
        assert(base.length == 8 * sliceBytes);
        for (unsigned z = 0; z < 8; z++)
            for (unsigned other = 0; other < z; other++)
                assert(memcmp((const uint8_t *)base.bytes + z * sliceBytes,
                              (const uint8_t *)base.bytes + other * sliceBytes,
                              sliceBytes));
    }
    assert([bcu_packed_reads(a, ar) isEqualToData:bcu_packed_reads(b, br)]);
    for (unsigned y = 0; y < 4; y++)
        assert(!memcmp(pixel(as, 4, 4, 0, y, 0), pixel(bs, 4, 4, 0, y, 0),
                       4 * 16));
    NSData *aw = nv2a_metal_texture_snapshot(a.texture, commands, &error),
           *bw = nv2a_metal_texture_snapshot(b.texture, commands, &error);
    require(aw && bw, error);
    assert([aw isEqualToData:bw]);
    NSMutableData *raw = [NSMutableData new];
    for (NSData *g in goldens)
        [raw appendData:g];
    assert(aw.length == 40 + raw.length &&
           !memcmp((const uint8_t *)aw.bytes + 40, raw.bytes, raw.length));
    if (layout == 3) {
        id<MTLTexture> restored =
            nv2a_metal_texture_restore(aw, commands, &error);
        require(restored != nil, error);
        NSData *again = nv2a_metal_texture_snapshot(restored, commands, &error);
        require(again != nil, error);
        assert([aw isEqualToData:again]);
    }
    assert(a.sourceLength == length && b.sourceLength == length &&
           a.texture.pixelFormat == MTLPixelFormatRGBA8Unorm);
    assert([bcu_buffer_bytes(source) isEqualToData:sourceBytes]);
    unsigned w, h, d;
    bcu_dimensions(s, &w, &h, &d);
    NSUInteger expectedBlocks = 0, expectedTexels = 0;
    for (unsigned l = 0; l < s.levels; l++) {
        unsigned lw = MAX(1u, w >> l), lh = MAX(1u, h >> l),
                 ld = MAX(1u, d >> l);
        expectedBlocks += (NSUInteger)((lw + 3) / 4) * ((lh + 3) / 4) * ld;
        expectedTexels += (NSUInteger)lw * lh * ld;
    }
    expectedBlocks *= s.cubemap ? 6 : 1;
    expectedTexels *= s.cubemap ? 6 : 1;
    assert(dispatches == (s.cubemap ? 6u : 1u) * s.levels &&
           blocks == expectedBlocks && oldThreads == expectedTexels);
    uploads += 2;
}
static NSData *bcu_buffer_bytes(id<MTLBuffer> source)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    id<MTLBuffer> out =
        [commands.device newBufferWithLength:source.length
                                     options:MTLResourceStorageModeShared];
    require(out && [commands addResource:source error:&error] &&
                [commands addResource:out error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:source
             sourceOffset:0
                 toBuffer:out
        destinationOffset:0
                     size:source.length];
    [e endEncoding];
    finish();
    return [NSData dataWithBytes:out.contents length:out.length];
}
static void bcu_raw_golden(NV2AMetalTextureUploadResult *r,
                           NSArray<NSData *> *goldens)
{
    NSError *error = nil;
    NSData *wire = nv2a_metal_texture_snapshot(r.texture, commands, &error);
    require(wire != nil, error);
    NSMutableData *expected = [NSMutableData new];
    for (NSData *g in goldens)
        [expected appendData:g];
    assert(wire.length == 40 + expected.length &&
           !memcmp((const uint8_t *)wire.bytes + 40, expected.bytes,
                   expected.length));
}
static void bcu_collect(NV2AMetalTextureUploadResult *r,
                        NSMutableArray<id<MTLBuffer>> *reads)
{
    for (unsigned face = 0;
         face < (r.texture.textureType == MTLTextureTypeCube ? 6u : 1u); face++)
        for (unsigned level = 0; level < r.texture.mipmapLevelCount; level++)
            [reads addObject:read_texture(r.texture, level, face)];
}
static void bcu_multi(void)
{
    NSError *error = nil;
    NV2AMetalTextureUpload *a =
        [[NV2AMetalTextureUpload alloc] initWithDevice:commands.device
                                                 error:&error];
    BCBlockReference *b =
        [[BCBlockReference alloc] initWithDevice:commands.device error:&error];
    require(a && b, error);
    require([commands beginWithError:&error] != nil, error);
    TextureUploadTestCommands *measured = (TextureUploadTestCommands *)commands;
    measured.measureScratch = YES;
    NSMutableArray<NV2AMetalTextureUploadResult *> *results =
        [NSMutableArray new];
    NSMutableArray<NSArray<NSData *> *> *goldens = [NSMutableArray new];
    NSMutableArray<id<MTLBuffer>> *scratches = [NSMutableArray new];
    for (unsigned i = 0; i < 3; i++) {
        NV2AMetalTextureShape s = bcu_shape(i, 0);
        s.levels = 1;
        s.max_level = 0;
        s.width = i == 2 ? 4 : 8;
        s.height = 8;
        NSMutableArray *g = [NSMutableArray new];
        NSData *bytes = bcu_source(s, i, i + 1, g);
        id<MTLBuffer> source = buffer(bytes.bytes, bytes.length);
        NV2AMetalTextureUploadResult *one = bcu_encode(a, s, source, 3, &error);
        require(one != nil, error);
        [results addObject:one];
        [goldens addObject:g];
        [scratches addObject:measured.lastTransferScratch];
        one = bcu_encode(b, s, source, 3, &error);
        require(one != nil, error);
        [results addObject:one];
        [goldens addObject:g];
        [scratches addObject:measured.lastTransferScratch];
    }
    measured.measureScratch = NO;
    id<MTLBuffer> scratch = scratches.lastObject;
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e fillBuffer:scratch range:NSMakeRange(0, scratch.length) value:0xcd];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    NSMutableArray<NSArray<id<MTLBuffer>> *> *reads = [NSMutableArray new];
    for (NV2AMetalTextureUploadResult *r in results) {
        NSMutableArray *one = [NSMutableArray new];
        bcu_collect(r, one);
        [reads addObject:one];
    }
    a = nil;
    b = nil; /* Commands, not external owners, retain pending arguments. */
    finish();
    for (unsigned i = 0; i < 6; i++) {
        assert(results[i].faults.length >= 4 &&
               !*(const uint32_t *)results[i].faults.contents);
        bcu_raw_golden(results[i], goldens[i]);
        if (i & 1)
            assert([bcu_packed_reads(results[i - 1], (id)reads[i - 1])
                isEqualToData:bcu_packed_reads(results[i], (id)reads[i])]);
    }
    for (id<MTLBuffer> same in scratches)
        assert(same == scratch);
    for (unsigned i = 1; i < 6; i++)
        assert(results[i].texture != results[0].texture);
}
static void bcu_cold(void)
{
    for (unsigned kind = 0; kind < 2; kind++) {
        NSError *error = nil;
        NV2AMetalTextureUpload *a =
            [[NV2AMetalTextureUpload alloc] initWithDevice:commands.device
                                                     error:&error];
        require(a != nil, error);
        NV2AMetalTextureShape s = bcu_shape(2, 0);
        s.levels = 1;
        s.max_level = 0;
        NSMutableArray *g = [NSMutableArray new];
        NSData *bytes = bcu_source(s, 2, 0, g);
        id<MTLBuffer> source = buffer(bytes.bytes, bytes.length);
        uint32_t initial = 0xcdcdcdcd;
        id<MTLBuffer> marker = buffer(&initial, 4);
        id<MTL4CommandBuffer> recording = [commands beginWithError:&error];
        require(recording != nil, error);
        require([commands addResource:marker error:&error], error);
        id<MTL4ComputeCommandEncoder> e =
            [commands.commandBuffer computeCommandEncoder];
        require(e != nil, nil);
        [e fillBuffer:marker range:NSMakeRange(0, 4) value:0x5a];
        [e endEncoding];
        uint64_t serial = commands.recordingSerial;
        NSUInteger sealed = commands.sealedBufferCount;
        NV2AMetalSubmission *receipt = commands.lastSubmitted;
        bcu_fail_function = kind == 0;
        bcu_fail_table = kind == 1;
        bcu_encoders = bcu_dispatches = 0;
        NV2AMetalTextureUploadResult *failed =
            bcu_encode(a, s, source, 3, &error);
        BOOL preserved = commands.commandBuffer == recording &&
                         commands.recordingSerial == serial &&
                         commands.sealedBufferCount == sealed &&
                         commands.lastSubmitted == receipt;
        NSUInteger encoders = bcu_encoders, dispatches = bcu_dispatches;
        assert(!failed && error == bcu_failure && !bcu_fail_function &&
               !bcu_fail_table);
        error = nil;
        NV2AMetalTextureUploadResult *retry =
            bcu_encode(a, s, source, 3, &error);
        require(retry != nil, error);
        NSMutableArray *reads = [NSMutableArray new];
        bcu_collect(retry, reads);
        finish();
        bcu_verify(retry, s, g, reads);
        bcu_raw_golden(retry, g);
        assert(*(const uint32_t *)marker.contents == UINT32_C(0x5a5a5a5a));
        assert(preserved && !encoders && !dispatches &&
               ![a valueForKey:@"pipeline"] && ![a valueForKey:@"arguments"]);
    }
}
static void bcu_cancel_retry(void)
{
    NSError *error = nil;
    NV2AMetalTextureUpload *a =
        [[NV2AMetalTextureUpload alloc] initWithDevice:commands.device
                                                 error:&error];
    require(a != nil, error);
    NV2AMetalTextureShape s = bcu_shape(0, 0);
    s.levels = 1;
    s.max_level = 0;
    NSMutableArray *oldGolden = [NSMutableArray new];
    NSData *oldBytes = bcu_source(s, 0, 0, oldGolden);
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalTextureUploadResult *old =
        bcu_encode(a, s, buffer(oldBytes.bytes, oldBytes.length), 3, &error);
    require(old != nil, error);
    finish();
    NSData *oldWire =
        nv2a_metal_texture_snapshot(old.texture, commands, &error);
    require(oldWire != nil, error);
    NSMutableArray *freshGolden = [NSMutableArray new];
    NSData *freshBytes = bcu_source(s, 0, 1, freshGolden);
    id<MTLBuffer> source = buffer(freshBytes.bytes, freshBytes.length);
    uint32_t sentinel = 0xcdcdcdcd;
    id<MTLBuffer> cancelledMarker = buffer(&sentinel, 4);
    require([commands beginWithError:&error] != nil &&
                [commands addResource:cancelledMarker error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e fillBuffer:cancelledMarker range:NSMakeRange(0, 4) value:0x77];
    [e endEncoding];
    bcu_late_fail = YES;
    NV2AMetalTextureUploadResult *encoded = bcu_encode(a, s, source, 3, &error);
    assert(!encoded && error == bcu_failure && !bcu_late_fail);
    /* Simulated caller failure AFTER real native work, before acceptance. */
    [commands cancelUnsealed];
    error = nil;
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalTextureUploadResult *retry = bcu_encode(a, s, source, 3, &error);
    require(retry != nil, error);
    NSMutableArray *reads = [NSMutableArray new];
    bcu_collect(retry, reads);
    finish();
    bcu_verify(retry, s, freshGolden, reads);
    bcu_raw_golden(retry, freshGolden);
    bcu_raw_golden(old, oldGolden);
    NSData *again = nv2a_metal_texture_snapshot(old.texture, commands, &error);
    require(again != nil, error);
    assert([oldWire isEqualToData:again] &&
           *(const uint32_t *)cancelledMarker.contents == sentinel);
}
static void bcu_rejections(void)
{
    NSError *error = nil;
    NV2AMetalTextureUpload *a =
        [[NV2AMetalTextureUpload alloc] initWithDevice:commands.device
                                                 error:&error];
    BCBlockReference *b =
        [[BCBlockReference alloc] initWithDevice:commands.device error:&error];
    require(a && b, error);
    NV2AMetalTextureShape good = bcu_shape(1, 0);
    NSMutableArray *g = [NSMutableArray new];
    NSData *bytes = bcu_source(good, 1, 0, g);
    id<MTLBuffer> source = buffer(bytes.bytes, bytes.length);
    require([commands beginWithError:&error] != nil, error);
    for (unsigned kind = 0; kind < 4; kind++) {
        NV2AMetalTextureShape s = good;
        NSUInteger offset = 3;
        if (kind == 0)
            offset = source.length;
        if (kind == 1)
            s.levels = 16;
        if (kind == 2)
            s.signed_channels = 1;
        if (kind == 3)
            s.min_level = s.levels;
        bcu_encoders = bcu_dispatches = 0;
        NSError *ae = nil, *be = nil;
        NV2AMetalTextureUploadResult *one =
            bcu_encode(a, s, source, offset, &ae);
        NV2AMetalTextureUploadResult *two =
            bcu_encode(b, s, source, offset, &be);
        assert(
            !one && !two && ae && be && [ae.domain isEqualToString:be.domain] &&
            ae.code == be.code &&
            [ae.localizedDescription isEqualToString:be.localizedDescription] &&
            !bcu_encoders && !bcu_dispatches);
    }
    NV2AMetalTextureUploadResult *retry =
        bcu_encode(a, good, source, 3, &error);
    require(retry != nil, error);
    NSMutableArray *reads = [NSMutableArray new];
    bcu_collect(retry, reads);
    finish();
    bcu_verify(retry, good, g, reads);
    bcu_raw_golden(retry, g);
}
static void bc_block_upload_tests(void)
{
    NSError *error = nil;
    NV2AMetalCommands *saved = commands;
    commands = [[TextureUploadTestCommands alloc] initWithDevice:saved.device
                                                           error:&error];
    require(commands != nil, error);
    require([commands beginWithError:&error] != nil, error);
    id<MTL4ComputeCommandEncoder> probe =
        [commands.commandBuffer computeCommandEncoder];
    require(probe != nil, nil);
    Method dispatch = class_getInstanceMethod(
        object_getClass(probe),
        @selector(dispatchThreads:threadsPerThreadgroup:));
    Method encoder =
        class_getInstanceMethod(object_getClass(commands.commandBuffer),
                                @selector(computeCommandEncoder));
    [probe endEncoding];
    [commands cancelUnsealed];
    Method function = class_getInstanceMethod(
        NV2AMetalShaderLibrary.class, @selector(computeFunction:error:));
    Class dc = object_getClass(commands.device);
    Method originalTable = class_getInstanceMethod(
        dc, @selector(newArgumentTableWithDescriptor:error:));
    Method replacement = class_getInstanceMethod(
        NSObject.class, @selector(bcu_newArgumentTableWithDescriptor:error:));
    class_addMethod(dc, @selector(newArgumentTableWithDescriptor:error:),
                    method_getImplementation(originalTable),
                    method_getTypeEncoding(originalTable));
    class_addMethod(dc, @selector(bcu_newArgumentTableWithDescriptor:error:),
                    method_getImplementation(replacement),
                    method_getTypeEncoding(replacement));
    originalTable = class_getInstanceMethod(
        dc, @selector(newArgumentTableWithDescriptor:error:));
    replacement = class_getInstanceMethod(
        dc, @selector(bcu_newArgumentTableWithDescriptor:error:));
    assert(dispatch && encoder && function && originalTable && replacement);
    bcu_dispatch_original = (void *)method_getImplementation(dispatch);
    bcu_encoder_original = (void *)method_getImplementation(encoder);
    bcu_function_original = (void *)method_getImplementation(function);
    bcu_failure =
        [NSError errorWithDomain:@"test.bc-block-upload"
                            code:1
                        userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"simulated block decoder preparation failure"
                        }];
    method_setImplementation(dispatch, (IMP)bcu_dispatch);
    method_setImplementation(encoder, (IMP)bcu_encoder);
    method_setImplementation(function, (IMP)bcu_function);
    method_exchangeImplementations(originalTable, replacement);
    @try {
        for (unsigned f = 0; f < 3; f++)
            for (unsigned l = 0; l < 4; l++)
                bcu_pair(f, l);
        bcu_multi();
        bcu_cold();
        bcu_cancel_retry();
        bcu_rejections();
    } @finally {
        bcu_scope = bcu_preparing = bcu_late_fail = NO;
        bcu_fail_function = bcu_fail_table = 0;
        bcu_failure = nil;
        method_exchangeImplementations(originalTable, replacement);
        method_setImplementation(function, (IMP)bcu_function_original);
        method_setImplementation(encoder, (IMP)bcu_encoder_original);
        method_setImplementation(dispatch, (IMP)bcu_dispatch_original);
        commands = saved;
    }
    puts("BC block upload:16 native groups, all subresource "
         "bytes/faults/literal palettes and actual PixelShader sampling vs "
         "unchanged old GPU decoder; same-recording scratch/owner lifetime, "
         "simulated cold/caller failures, cancel/retry and preflight guards "
         "PASS");
}
#endif
