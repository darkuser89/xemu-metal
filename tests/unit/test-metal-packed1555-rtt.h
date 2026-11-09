/* Exact packed 1555 RTT capture versus the original RAM download/decoder.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PACKED1555_RTT_H
#define TEST_METAL_PACKED1555_RTT_H

@interface NV2AMetalTextureCache (Packed1555RTTTest)
- (BOOL)canCapturePacked1555Surface:(NV2AMetalCachedSurface *)surface
                             format:(unsigned)format;
@end
@interface Packed1555Fixture : SwizzledRTTFixture
@end
@implementation Packed1555Fixture
@end
static _Thread_local BOOL p55_reference, p55_scope, p55_cold;
static _Thread_local unsigned p55_downloads, p55_vram_downloads,
    p55_private_downloads, p55_failure_kind;
static _Thread_local __unsafe_unretained Packed1555Fixture *p55_active;
static _Thread_local uint64_t p55_addresses[4];
static NSError *p55_failure;
static BOOL (*p55_admit_original)(id, SEL, NV2AMetalCachedSurface *, unsigned);
static BOOL p55_admit(id owner, SEL selector, NV2AMetalCachedSurface *surface,
                      unsigned format)
{
    BOOL allowed = p55_admit_original(owner, selector, surface, format);
    return !(p55_reference && owner == p55_active->textures) && allowed;
}
static BOOL (*p55_download_original)(id, SEL, id<MTLBuffer>, NSUInteger, BOOL,
                                     BOOL, BOOL, NV2AMetalCommands *,
                                     NSError **);
static BOOL p55_download(id owner, SEL selector, id<MTLBuffer> destination,
                         NSUInteger offset, BOOL swizzle, BOOL flip,
                         BOOL downscale, NV2AMetalCommands *queue,
                         NSError **error)
{
    if (p55_scope && owner == p55_active->surface.transfer) {
        unsigned slot = p55_downloads++;
        p55_vram_downloads += destination == p55_active->ram;
        p55_private_downloads +=
            destination.storageMode == MTLStorageModePrivate;
        if (slot < (sizeof(p55_addresses) / sizeof(p55_addresses[0])))
            p55_addresses[slot] = destination.gpuAddress + offset;
    }
    return p55_download_original(owner, selector, destination, offset, swizzle,
                                 flip, downscale, queue, error);
}
static void p55_store(void *destination, uint16_t value)
{
    uint8_t *p = destination;
    p[0] = value;
    p[1] = value >> 8;
}
static uint16_t p55_load(const void *source)
{
    const uint8_t *p = source;
    return (uint16_t)(p[0] | (unsigned)p[1] << 8);
}
static uint16_t p55_word(unsigned x, unsigned y, unsigned width, unsigned phase,
                         uint16_t uniform)
{
    return uniform ? uniform :
                     (uint16_t)((y * width + x) * 40503u + phase * 137u);
}
static void p55_seed(Packed1555Fixture *f, unsigned phase, BOOL complete)
{
    NSError *error = nil;
    /* A complete GPU replacement needs neither an initial source upload nor
     * its argument table. This also makes cold download-factory tests real. */
    f->surface = [f->cache selectSurfaceAtAddress:4096
                                           config:&f->config
                                            frame:phase + 1
                                            error:&error];
    require(f->surface && [f->cache prepareSelectedSurface:f->surface
                                        discardingContents:YES
                                                     error:&error],
            error);
    id<MTLTexture> texture = [f->surface.transfer textureForCommands:f->queue
                                                               error:&error];
    require(texture != nil, error);
    NSUInteger pitch = (texture.width * 2 + 255) & ~(NSUInteger)255;
    id<MTLBuffer> data =
        [f->queue.device newBufferWithLength:pitch * texture.height
                                     options:MTLResourceStorageModeShared];
    require(data != nil, nil);
    memset(data.contents, 0x91, data.length);
    for (NSUInteger y = 0; y < texture.height; y++)
        for (NSUInteger x = 0; x < texture.width; x++) {
            uint16_t word = p55_word(x / f->config.scale, y / f->config.scale,
                                     f->config.width, phase, 0);
            if (x % f->config.scale || y % f->config.scale)
                word ^=
                    UINT16_C(0x83df); /* Wrong sample is never the same RGB. */
            p55_store((uint8_t *)data.contents + y * pitch + x * 2, word);
        }
    require([f->queue addResource:data error:&error] &&
                [f->queue addResource:texture error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [f->queue.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:data
               sourceOffset:0
          sourceBytesPerRow:pitch
        sourceBytesPerImage:data.length
                 sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                  toTexture:texture
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    require([f->cache markWritten:f->surface
                replacingContents:YES
                            error:&error],
            error);
    if (complete)
        rck_finish(f->cache);
}
static Packed1555Fixture *p55_fixture(id<MTLDevice> device, unsigned family,
                                      unsigned order, unsigned scale,
                                      BOOL small)
{
    NSError *error = nil;
    Packed1555Fixture *f = [Packed1555Fixture new];
    f->queue = [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    f->ram = [device newBufferWithLength:262144
                                 options:MTLResourceStorageModeShared];
    require(f->queue && f->ram, error);
    memset(f->ram.contents, 0x51, f->ram.length);
    __weak Packed1555Fixture *weak = f;
    f->cache = [[NV2AMetalSurfaceCache alloc]
        initWithCommands:f->queue
                    vram:f->ram
            didWriteVRAM:^(NSUInteger address, NSUInteger length) {
              Packed1555Fixture *owner = weak;
              assert(owner && address == 4096 &&
                     length == owner->config.pitch * owner->config.height);
              owner->notifications++;
            }
                   error:&error];
    require(f->cache != nil, error);
    unsigned width = small ? (order == 2 ? 17 : 16) : (order == 2 ? 257 : 256);
    unsigned height = small ? 16 : 256;
    f->config = (NV2AMetalSurfaceConfig){
        .format = family ? NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5 :
                           NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5,
        .width = width,
        .height = height,
        .pitch = width * 2 + (order == 2 ? 6 : 0),
        .scale = scale,
        .color = YES,
        .swizzle = order != 2
    };
    const unsigned formats[] = {
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A1R5G5B5,
        NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5
    };
    f->source =
        (NV2AMetalTextureSource){ .address = 4096,
                                  .length = f->config.pitch * height,
                                  .shape = { .format = formats[order],
                                             .dimension = 2,
                                             .width = width,
                                             .height = height,
                                             .depth = 1,
                                             .levels = 1,
                                             .pitch = f->config.pitch } };
    p55_seed(f, 0, YES);
    f->textures = [[NV2AMetalTextureCache alloc] initWithSurfaces:f->cache
                                                            error:&error];
    require(f->textures != nil, error);
    return f;
}
static unsigned p55_morton(unsigned x, unsigned y, unsigned width,
                           unsigned height)
{
    unsigned offset = 0, destination = 0;
    for (unsigned bit = 0; (1u << bit) < MAX(width, height); bit++) {
        if ((1u << bit) < width)
            offset |= ((x >> bit) & 1u) << destination++;
        if ((1u << bit) < height)
            offset |= ((y >> bit) & 1u) << destination++;
    }
    return offset;
}
static void p55_ram(Packed1555Fixture *f, unsigned phase, BOOL downloaded)
{
    const uint8_t *ram = (const uint8_t *)f->ram.contents + 4096;
    if (!downloaded) {
        for (NSUInteger i = 0; i < f->source.length; i++)
            assert(ram[i] == 0x51);
        return;
    }
    for (unsigned y = 0; y < f->config.height; y++) {
        for (unsigned x = 0; x < f->config.width; x++) {
            NSUInteger offset =
                f->config.swizzle ?
                    p55_morton(x, y, f->config.width, f->config.height) * 2 :
                    y * f->config.pitch + x * 2;
            assert(p55_load(ram + offset) ==
                   p55_word(x, y, f->config.width, phase, 0));
        }
        if (!f->config.swizzle)
            for (unsigned x = f->config.width * 2; x < f->config.pitch; x++)
                assert(ram[y * f->config.pitch + x] == 0x51);
    }
}
/* Same production sampler path as the channel tests, additionally counting
 * passing samples and leaving a visible sentinel where alpha kill discards. */
static id<MTLBuffer> p55_sample(Packed1555Fixture *f,
                                NV2AMetalCachedTexture *texture,
                                NV2AMetalPixelShader *shader, BOOL kill,
                                id<MTLBuffer> *query)
{
    NSError *error = nil;
    unsigned w = (unsigned)texture.binding.texture.width;
    unsigned h = (unsigned)texture.binding.texture.height;
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:w
                                    height:h
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> target = [f->queue.device newTextureWithDescriptor:td];
    *query = [f->queue.device newBufferWithLength:8
                                          options:MTLResourceStorageModeShared];
    require(target && *query, nil);
    memset((*query).contents, 0, 8);
    const float xy[6][2] = { { 0, 0 }, { 1, 0 }, { 0, 1 },
                             { 1, 0 }, { 1, 1 }, { 0, 1 } };
    NV2AMetalVertex v[6] = { 0 };
    for (unsigned i = 0; i < 6; i++) {
        v[i].clip[0] = 2 * xy[i][0] - 1;
        v[i].clip[1] = 1 - 2 * xy[i][1];
        v[i].clip[2] = .5f;
        v[i].clip[3] = 1;
        v[i].texcoord[0][0] = xy[i][0] * (texture.rectangle ? w : 1);
        v[i].texcoord[0][1] = xy[i][1] * (texture.rectangle ? h : 1);
        v[i].texcoord[0][3] = 1;
        v[i].plane[0][2] = v[i].plane[1][2] = v[i].plane[2][2] = .5f;
    }
    id<MTLBuffer> vertices =
        [f->queue.device newBufferWithBytes:v
                                     length:sizeof(v)
                                    options:MTLResourceStorageModeShared];
    require(vertices != nil, nil);
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.shader_stage_program = PS_TEXTUREMODES_PROJECT2D;
    u.combiner.final_inputs[0] = PS_REGISTER_T0;
    u.combiner.final_inputs[1] = (PS_REGISTER_T0 | PS_CHANNEL_ALPHA) << 8;
    u.surface_scale[0] = u.surface_scale[1] = 1;
    u.clip_range[1] = u.clip_range[3] = 65535;
    u.clip_regions[0][2] = w;
    u.clip_regions[0][3] = h;
    u.textures[0].dimension = 2;
    u.textures[0].rectangle = texture.rectangle;
    u.textures[0].scale = texture.scale;
    u.textures[0].sampling = texture.binding.sampling;
    u.textures[0].alphakill = kill;
    NV2AMetalPixelTexture bindings[4] = { 0 };
    bindings[0].texture = texture.binding.texture;
    bindings[0].sampler = texture.binding.sampler;
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor =
        MTLClearColorMake(-.25, .125, 1.5, -.5);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.visibilityResultBuffer = *query;
    pass.visibilityResultType = MTLVisibilityResultTypeReset;
    require([shader encodeVertices:vertices
                             count:6
                         primitive:MTLPrimitiveTypeTriangle
                          uniforms:&u
                          textures:bindings
                              pass:pass
                      depthStencil:nil
                          commands:f->queue
                             error:&error],
            error);
    return test_metal_read_2d_texture(f->queue, target, 0);
}
static NSData *p55_observe(Packed1555Fixture *f,
                           NV2AMetalCachedTexture *texture,
                           NV2AMetalPixelShader *shader, unsigned order,
                           unsigned phase, uint16_t uniform, BOOL kill)
{
    NSError *error = nil;
    require([f->cache beginRecordingWithError:&error], error);
    id<MTLBuffer> raw =
        test_metal_read_2d_texture(f->queue, texture.binding.texture, 0);
    id<MTLBuffer> query = nil;
    id<MTLBuffer> sampled = p55_sample(f, texture, shader, kill, &query);
    rck_finish(f->cache);
    require([texture validateCompletedWithError:&error], error);
    NSData *read = srt_pack(raw, f->config.width, f->config.height);
    NSData *sample = srt_pack(sampled, f->config.width, f->config.height);
    const float *a = read.bytes, *b = sample.bytes;
    const float sentinel[4] = { -.25f, .125f, 1.5f, -.5f };
    uint64_t passCount = 0;
    for (unsigned y = 0; y < f->config.height; y++)
        for (unsigned x = 0; x < f->config.width; x++) {
            uint16_t word = p55_word(x, y, f->config.width, phase, uniform);
            float expected[4] = { ((word >> 10) & 31) / 31.f,
                                  ((word >> 5) & 31) / 31.f, (word & 31) / 31.f,
                                  order ? (float)(word >> 15) : 1 };
            BOOL passed = !kill || expected[3] != 0;
            passCount += passed;
            for (unsigned k = 0; k < 4; k++) {
                NSUInteger i = ((NSUInteger)y * f->config.width + x) * 4 + k;
                float sampleExpected = passed ? expected[k] : sentinel[k];
                if (fabsf(a[i] - expected[k]) > .000001f ||
                    fabsf(b[i] - sampleExpected) > .000001f) {
                    fprintf(stderr,
                            "Packed1555 order%u scale%u phase%u xy%u,%u "
                            "lane%u read%.9g sample%.9g expected%.9g/%.9g\n",
                            order, f->config.scale, phase, x, y, k, a[i], b[i],
                            expected[k], sampleExpected);
                    abort();
                }
            }
        }
    uint64_t count;
    memcpy(&count, query.contents, sizeof(count));
    assert(count >= passCount);
    NSMutableData *result = [read mutableCopy];
    [result appendData:sample];
    [result appendBytes:&count length:sizeof(count)];
    return result;
}

typedef struct Packed1555Route {
    unsigned copies, dispatches, uploads, downloads, vram, privateBuffers;
    uint64_t address;
} Packed1555Route;
static NV2AMetalCachedTexture *p55_capture(Packed1555Fixture *f,
                                           Packed1555Route *route)
{
    NSError *error = nil;
    NV2AMetalSamplerConfig sampler = policy();
    p55_downloads = p55_vram_downloads = p55_private_downloads = 0;
    memset(p55_addresses, 0, sizeof(p55_addresses));
    x8r_begin_scope();
    p55_scope = YES;
    NV2AMetalCachedTexture *t = [f->textures prepareSource:&f->source
                                                   sampler:&sampler
                                                     frame:10
                                                     error:&error];
    p55_scope = NO;
    rck_scope = 0;
    *route = (Packed1555Route){ rck_copies,         rck_dispatches,
                                x8r_uploads,        p55_downloads,
                                p55_vram_downloads, p55_private_downloads,
                                p55_addresses[0] };
    require(t != nil, error);
    return t;
}
static NSData *p55_pair(id<MTLDevice> device, NV2AMetalPixelShader *shader,
                        unsigned family, unsigned order, unsigned scale,
                        BOOL reference)
{
    Packed1555Fixture *f = p55_fixture(device, family, order, scale, NO);
    p55_active = f;
    p55_reference = reference;
    Packed1555Route route;
    NV2AMetalCachedTexture *old = p55_capture(f, &route);
    BOOL lifecycle = !family && scale == 2;
    if (lifecycle && !reference) {
        [f->cache cancel];
        NSError *error = nil;
        assert(![old validateCompletedWithError:&error]);
        old = p55_capture(f, &route);
    }
    NSMutableData *result =
        [p55_observe(f, old, shader, order, 0, 0, YES) mutableCopy];
    // Logical raw decode, actual sampler pixels and visibility precede route
    // checks.
    p55_ram(f, 0, reference);
    if (reference)
        assert(route.downloads == 1 && route.vram == 1 &&
               f->notifications == 1);
    else {
        assert(!route.vram && !f->notifications && f->surface.dirty);
        assert(scale == 1 ? !route.downloads && !route.uploads &&
                                route.copies == 1 && !route.dispatches :
                            route.downloads == 1 && route.privateBuffers == 1 &&
                                route.dispatches == 1 && route.uploads == 1 &&
                                !route.copies);
    }
    if (lifecycle) {
        NSError *error = nil;
        p55_seed(f, 1, YES);
        require([f->cache beginRecordingWithError:&error], error);
        id<MTLBuffer> inFlight =
            test_metal_read_2d_texture(f->queue, old.binding.texture, 0);
        NV2AMetalCachedTexture *fresh = p55_capture(f, &route);
        NSData *second = p55_observe(f, fresh, shader, order, 1, 0, NO);
        NSData *previous =
            srt_pack(inFlight, f->config.width, f->config.height);
        assert(!memcmp(previous.bytes, result.bytes, previous.length));
        [result appendData:second];
        require([f->cache resolveCPUAccessAtAddress:4096
                                             length:f->source.length
                                              write:YES
                                              error:&error],
                error);
        for (unsigned y = 0; y < f->config.height; y++)
            for (unsigned x = 0; x < f->config.width; x++) {
                NSUInteger offset =
                    f->config.swizzle ?
                        p55_morton(x, y, f->config.width, f->config.height) *
                            2 :
                        y * f->config.pitch + x * 2;
                p55_store((uint8_t *)f->ram.contents + 4096 + offset,
                          UINT16_C(0x2d6b));
            }
        NV2AMetalCachedTexture *alias = p55_capture(f, &route);
        [result
            appendData:p55_observe(f, alias, shader, order, 0, 0x2d6b, YES)];
        [result appendData:p55_observe(f, fresh, shader, order, 1, 0, NO)];
        NV2AMetalCommands *snap =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        require(snap != nil, error);
        NSData *wire =
            nv2a_metal_texture_snapshot(old.binding.texture, snap, &error);
        require(wire != nil, error);
        require([f->cache discardForRestoreWithError:&error], error);
        id<MTLTexture> restored =
            nv2a_metal_texture_restore(wire, snap, &error);
        require(restored && [snap beginWithError:&error] != nil, error);
        id<MTLBuffer> read = test_metal_read_2d_texture(snap, restored, 0);
        require(read && [snap submitWithError:&error] &&
                    [snap waitUntilIdleWithError:&error],
                error);
        NSData *pixels = srt_pack(read, f->config.width, f->config.height);
        assert(!memcmp(pixels.bytes, result.bytes, pixels.length));
        [result appendData:pixels];
    }
    p55_active = nil;
    p55_reference = NO;
    return result;
}
/* All private result buffers must coexist until the recording completes.
 * Later source updates, table bindings and scratch writes are real GPU work. */
static void p55_shared_recording(id<MTLDevice> device,
                                 NV2AMetalPixelShader *shader)
{
    Packed1555Fixture *f = p55_fixture(device, 0, 0, 2, YES);
    p55_active = f;
    p55_reference = NO;
    NV2AMetalCachedTexture *images[3] = { nil, nil, nil };
    Packed1555Route routes[3];
    id originalBuffer = nil;
    NV2AMetalSurfaceRecording *originalToken = nil;
    uint64_t serial = 0;
    BOOL same = YES;
    const unsigned orders[] = { 0, 1, 0 };
    for (unsigned i = 0; i < 3; i++) {
        if (i)
            p55_seed(f, i, NO);
        f->source.shape.format =
            orders[i] ? NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A1R5G5B5 :
                        NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5;
        images[i] = p55_capture(f, routes + i);
        if (!i) {
            originalBuffer = f->queue.commandBuffer;
            originalToken = f->cache.recording;
            serial = f->queue.recordingSerial;
        }
        same &= originalBuffer == f->queue.commandBuffer &&
                originalToken == f->cache.recording &&
                serial == f->queue.recordingSerial && !originalToken.submitted;
    }
    NSError *error = nil;
    id<MTLBuffer> scratch = [f->queue orderedTransferScratchWithLength:1
                                                                 error:&error];
    require(scratch != nil, error);
    id<MTL4ComputeCommandEncoder> e =
        [f->queue.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e fillBuffer:scratch range:NSMakeRange(0, scratch.length) value:0xa9];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    for (unsigned i = 0; i < 3; i++)
        (void)p55_observe(f, images[i], shader, orders[i], i, 0, YES);
    p55_ram(f, 2, NO);
    assert(same && !f->notifications);
    for (unsigned i = 0; i < 3; i++) {
        assert(routes[i].privateBuffers == 1 && routes[i].downloads == 1 &&
               !routes[i].vram && routes[i].address &&
               routes[i].address != scratch.gpuAddress);
        for (unsigned j = 0; j < i; j++)
            assert(routes[i].address != routes[j].address);
    }
    p55_active = nil;
}
static BOOL (*p55_prepare_original)(id, SEL, NSError **);
static BOOL p55_prepare(id owner, SEL selector, NSError **error)
{
    BOOL saved = p55_cold;
    p55_cold = p55_active && owner == p55_active->surface.transfer;
    @try {
        return p55_prepare_original(owner, selector, error);
    } @finally {
        p55_cold = saved;
    }
}
static void p55_error(NSError **error)
{
    if (error)
        *error = p55_failure;
    p55_failure_kind = 0;
}
static id (*p55_function_original)(id, SEL, NSString *, NSError **);
static id p55_function(id owner, SEL selector, NSString *name, NSError **error)
{
    if (p55_cold && p55_failure_kind == 1 &&
        [name isEqualToString:@"nv2a_surface_download"]) {
        p55_error(error);
        return nil;
    }
    return p55_function_original(owner, selector, name, error);
}
typedef id (*P55ArgumentFactory)(id, SEL, id, NSError **)
    __attribute__((ns_returns_retained));
static P55ArgumentFactory p55_arguments_original;
static id p55_arguments(id owner, SEL selector, id descriptor, NSError **error)
    __attribute__((ns_returns_retained));
static id p55_arguments(id owner, SEL selector, id descriptor, NSError **error)
{
    MTL4ArgumentTableDescriptor *layout = descriptor;
    if (p55_cold && p55_failure_kind == 2 && layout.maxBufferBindCount == 3 &&
        layout.maxTextureBindCount == 1) {
        p55_error(error);
        return nil;
    }
    return p55_arguments_original(owner, selector, descriptor, error);
}
static void p55_factory_failure(id<MTLDevice> device,
                                NV2AMetalPixelShader *shader, unsigned kind)
{
    Packed1555Fixture *f = p55_fixture(device, kind - 1, kind == 1 ? 1 : 2,
                                       kind == 1 ? 2 : 4, YES);
    p55_active = f;
    p55_reference = NO;
    NSError *error = nil;
    require([f->cache beginRecordingWithError:&error], error);
    id<MTLBuffer> marker =
        [device newBufferWithLength:4 options:MTLResourceStorageModeShared];
    require(marker && [f->queue addResource:marker error:&error], error);
    memset(marker.contents, 0xcd, 4);
    id<MTL4ComputeCommandEncoder> e =
        [f->queue.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e fillBuffer:marker range:NSMakeRange(0, 4) value:0x6b];
    [e endEncoding];
    id buffer = f->queue.commandBuffer;
    NV2AMetalSurfaceRecording *token = f->cache.recording;
    NV2AMetalSubmission *receipt = f->queue.lastSubmitted;
    uint64_t serial = f->queue.recordingSerial, batch = f->queue.batchSerial;
    NSUInteger sealed = f->queue.sealedBufferCount;
    uint64_t generation = f->surface.generation;
    p55_failure = [NSError errorWithDomain:@"test.packed1555.factory"
                                      code:kind
                                  userInfo:nil];
    p55_failure_kind = kind;
    NV2AMetalSamplerConfig sampler = policy();
    NV2AMetalCachedTexture *failed = [f->textures prepareSource:&f->source
                                                        sampler:&sampler
                                                          frame:10
                                                          error:&error];
    BOOL injected = !failed && error == p55_failure && !p55_failure_kind;
    BOOL preserved =
        f->queue.commandBuffer == buffer && f->cache.recording == token &&
        f->queue.lastSubmitted == receipt &&
        f->queue.recordingSerial == serial && f->queue.batchSerial == batch &&
        f->queue.sealedBufferCount == sealed && !token.cancelled &&
        f->surface.generation == generation &&
        ![[f->surface valueForKey:@"recording"] boolValue] && f->surface.dirty;
    p55_failure_kind = 0;
    error = nil;
    Packed1555Route route;
    NV2AMetalCachedTexture *retry = p55_capture(f, &route);
    (void)p55_observe(f, retry, shader, kind == 1 ? 1 : 2, 0, 0, YES);
    p55_ram(f, 0, NO);
    assert(*(uint32_t *)marker.contents == UINT32_C(0x6b6b6b6b));
    assert(injected && preserved && !f->notifications &&
           route.privateBuffers == 1);
    p55_failure = nil;
    p55_active = nil;
}
static void packed1555_rtt_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalPixelShader *shader =
        [[NV2AMetalPixelShader alloc] initWithDevice:device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    NV2AMetalCommands *probe =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(shader && probe && [probe beginWithError:&error] != nil, error);
    id e = [probe.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    Method methods[] = {
        class_getInstanceMethod(NV2AMetalTextureCache.class,
                                @selector(canCapturePacked1555Surface:format:)),
        class_getInstanceMethod(
            [e class],
            @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:
                      sourceSize:toTexture:destinationSlice:destinationLevel:
                      destinationOrigin:)),
        class_getInstanceMethod(
            [e class], @selector(dispatchThreads:threadsPerThreadgroup:)),
        class_getInstanceMethod(
            [e class],
            @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:
                      sourceBytesPerImage:sourceSize:toTexture:destinationSlice:
                      destinationLevel:destinationOrigin:)),
        class_getInstanceMethod(NV2AMetalSurfaceTransfer.class,
                                @selector(encodeDownloadToBuffer:offset:swizzle:
                                          flip:downscale:commands:error:)),
        class_getInstanceMethod(NV2AMetalSurfaceTransfer.class,
                                @selector(prepareDownloadWithError:)),
        class_getInstanceMethod(NV2AMetalShaderLibrary.class,
                                @selector(computeFunction:error:)),
        class_getInstanceMethod(
            [device class], @selector(newArgumentTableWithDescriptor:error:))
    };
    IMP originals[(sizeof(methods) / sizeof(methods[0]))];
    IMP replacements[] = { (IMP)p55_admit,    (IMP)rck_copy,
                           (IMP)rck_dispatch, (IMP)x8r_upload,
                           (IMP)p55_download, (IMP)p55_prepare,
                           (IMP)p55_function, (IMP)p55_arguments };
    for (unsigned i = 0; i < (sizeof(methods) / sizeof(methods[0])); i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    p55_admit_original = (void *)originals[0];
    rck_copy_original = (void *)originals[1];
    rck_dispatch_original = (void *)originals[2];
    x8r_upload_original = (void *)originals[3];
    p55_download_original = (void *)originals[4];
    p55_prepare_original = (void *)originals[5];
    p55_function_original = (void *)originals[6];
    p55_arguments_original = (void *)originals[7];
    [e endEncoding];
    [probe cancel];
    for (unsigned i = 0; i < (sizeof(methods) / sizeof(methods[0])); i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        for (unsigned family = 0; family < 2; family++)
            for (unsigned order = 0; order < 3; order++)
                for (unsigned scale = 1; scale <= 4; scale *= 2)
                    @autoreleasepool {
                        NSData *reference =
                            p55_pair(device, shader, family, order, scale, YES);
                        NSData *actual =
                            p55_pair(device, shader, family, order, scale, NO);
                        if (![reference isEqualToData:actual]) {
                            fprintf(stderr,
                                    "Packed1555 A/B bytes family%u order%u "
                                    "scale%u\n",
                                    family, order, scale);
                            abort();
                        }
                    }
        p55_shared_recording(device, shader);
        p55_factory_failure(device, shader, 1);
        p55_factory_failure(device, shader, 2);
    } @finally {
        for (unsigned i = 0; i < (sizeof(methods) / sizeof(methods[0])); i++)
            method_setImplementation(methods[i], originals[i]);
        p55_reference = p55_scope = p55_cold = NO;
        p55_active = nil;
        p55_failure = nil;
        p55_failure_kind = 0;
        rck_scope = 0;
    }
    puts("Packed1555 RTT:18 exhaustive native/old-RAM pairs (all65536words, "
         "both storedMSBs), GPUread/sampling/alphakill/query; scale1/2/4, "
         "odd/padded rectangle, offgrid, "
         "cancel/retry/oldread/CPUalias/snapshot, "
         "3 same-recording captures + scratch overwrite, 2 cold factory "
         "retries PASS");
    checks++;
}
#endif
