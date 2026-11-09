/* Cold texture producers do not close an unrelated native raster chain.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_RASTER_TEXTURE_UPLOAD_H
#define TEST_METAL_RASTER_TEXTURE_UPLOAD_H
#import "hw/xbox/nv2a/pgraph/metal/texture-cache.h"
#include "test-metal-texture-readback.h"
#include <math.h>

@interface NV2AMetalSurfaceCache (RasterTextureUploadTest)
- (BOOL)canQueueTextureUploadReadPatterns:
            (const NV2AMetalVRAMReadPattern *)patterns
                                    count:(NSUInteger)count
                                   bounds:(NSRange)bounds;
@end
@interface RasterUploadCommands : NV2AMetalCommands
@property(nonatomic) unsigned fullCalls, prefixCalls;
@property(nonatomic) BOOL forcePressure, releaseOnWait, gateInstalled;
@property(nonatomic) id<MTLSharedEvent> gate;
@end
@implementation RasterUploadCommands
- (BOOL)batchNeedsSubmit
{
    return _forcePressure || super.batchNeedsSubmit;
}
- (BOOL)submitWithError:(NSError **)error
{
    _fullCalls++;
    return [super submitWithError:error];
}
- (NV2AMetalSubmission *)submitProducersThroughSectionCount:(NSUInteger)count
                                                batchSerial:(uint64_t)serial
                                                      error:(NSError **)error
{
    _prefixCalls++;
    return [super submitProducersThroughSectionCount:count
                                         batchSerial:serial
                                               error:error];
}
- (void)releaseRasterGateForWait
{
    if (_releaseOnWait && _gateInstalled && !_gate.signaledValue)
        _gate.signaledValue = 1;
}
- (BOOL)waitForSubmission:(NV2AMetalSubmission *)submission
                    error:(NSError **)error
{
    [self releaseRasterGateForWait];
    return [super waitForSubmission:submission error:error];
}
- (BOOL)waitForProducersOfSubmission:(NV2AMetalSubmission *)submission
                               error:(NSError **)error
{
    [self releaseRasterGateForWait];
    return [super waitForProducersOfSubmission:submission error:error];
}
@end
@interface RasterUploadCache : NV2AMetalSurfaceCache
@property(nonatomic) BOOL forceOld;
@property(nonatomic) unsigned admissions, eligible;
@end
@implementation RasterUploadCache
- (BOOL)canQueueTextureUploadReadPatterns:
            (const NV2AMetalVRAMReadPattern *)patterns
                                    count:(NSUInteger)count
                                   bounds:(NSRange)bounds
{
    BOOL allowed = [super canQueueTextureUploadReadPatterns:patterns
                                                      count:count
                                                     bounds:bounds];
    _admissions++;
    _eligible += allowed;
    return !_forceOld && allowed;
}
@end
@interface RasterUploadFixture : NSObject {
@public
    RasterUploadCommands *queue;
    RasterUploadCache *cache;
    NV2AMetalTextureCache *textures;
    NV2AMetalPixelShader *pixel;
    NV2AMetalDrawState *raster;
    NV2AMetalCachedSurface *target;
    id<MTLBuffer> ram, query;
    id<MTL4CommandQueue> nativeQueue;
    __weak id<MTL4CommandBuffer> rasterA;
    NV2AMetalTextureSource source;
    unsigned notices;
}
@end
@implementation RasterUploadFixture
@end
static _Thread_local __unsafe_unretained RasterUploadFixture *rtu_active;
static _Thread_local BOOL rtu_upload_scope, rtu_fail_upload, rtu_bad_dependency;
static _Thread_local NSUInteger rtu_uploads;
static _Thread_local unsigned rtu_case;
static _Thread_local BOOL rtu_reference;
static NV2AMetalSubmission *rtu_dependency;
static NSError *rtu_failure;
static void (*rtu_commit_original)(id, SEL, const id<MTL4CommandBuffer> *,
                                   NSUInteger, MTL4CommitOptions *);
static void rtu_commit(id owner, SEL selector,
                       const id<MTL4CommandBuffer> *buffers, NSUInteger count,
                       MTL4CommitOptions *options)
{
    RasterUploadFixture *f = rtu_active;
    if (f && owner == f->nativeQueue && !f->queue.gateInstalled)
        for (NSUInteger i = 0; i < count; i++)
            if (buffers[i] == f->rasterA) {
                /* Real queue wait only when A actually commits. Earlier
                 * producer-prefix work is never artificially gated. */
                [f->nativeQueue waitForEvent:f->queue.gate value:1];
                f->queue.gateInstalled = YES;
                break;
            }
    rtu_commit_original(owner, selector, buffers, count, options);
}
static NV2AMetalTextureUploadResult *(*rtu_encode_original)(
    id, SEL, id<MTLBuffer>, NSUInteger, id<MTLBuffer>, NSUInteger, NSUInteger,
    const NV2AMetalTextureShape *, NV2AMetalCommands *, NSError **);
static NV2AMetalTextureUploadResult *
rtu_encode(id owner, SEL selector, id<MTLBuffer> data, NSUInteger offset,
           id<MTLBuffer> palette, NSUInteger paletteOffset,
           NSUInteger paletteLength, const NV2AMetalTextureShape *shape,
           NV2AMetalCommands *commands, NSError **error)
{
    NV2AMetalTextureUploadResult *result = rtu_encode_original(
        owner, selector, data, offset, palette, paletteOffset, paletteLength,
        shape, commands, error);
    if (rtu_upload_scope && rtu_active && commands == rtu_active->queue) {
        rtu_uploads += result != nil;
        if (result && rtu_fail_upload) {
            rtu_fail_upload = NO;
            if (error)
                *error = rtu_failure;
            return nil; /* Actual native work preceded this host failure. */
        }
    }
    return result;
}
static BOOL (*rtu_receipt_original)(id, SEL, NSError **);
static BOOL rtu_receipt(id owner, SEL selector, NSError **error)
{
    if (rtu_bad_dependency && owner == rtu_dependency &&
        rtu_receipt_original(owner, selector, NULL)) {
        if (error)
            *error = rtu_failure;
        return YES; /* Known-error simulation on a real pending receipt. */
    }
    return rtu_receipt_original(owner, selector, error);
}
static unsigned rtu_morton(unsigned x, unsigned y)
{
    unsigned at = 0;
    for (unsigned i = 0; i < 3; i++)
        at |= ((x >> i) & 1u) << (2 * i) | ((y >> i) & 1u) << (2 * i + 1);
    return at;
}
static uint32_t rtu_word(unsigned index)
{
    return UINT32_C(0xff0000ff) | (index * 3u & 255u) << 16 |
           (index * 5u & 255u) << 8;
}
static RasterUploadFixture *rtu_fixture(id<MTLDevice> device, unsigned format,
                                        BOOL reference)
{
    NSError *error = nil;
    RasterUploadFixture *f = [RasterUploadFixture new];
    f->queue = [[RasterUploadCommands alloc] initWithDevice:device
                                                      error:&error];
    f->ram = [device newBufferWithLength:65536
                                 options:MTLResourceStorageModeShared];
    require(f->queue && f->ram, error);
    memset(f->ram.contents, 0x37, f->ram.length);
    __weak RasterUploadFixture *weak = f;
    f->cache = [[RasterUploadCache alloc]
        initWithCommands:f->queue
                    vram:f->ram
            didWriteVRAM:^(NSUInteger address, NSUInteger length) {
              RasterUploadFixture *owner = weak;
              assert(owner && address < 65536 && length &&
                     length <= 65536 - address);
              owner->notices++;
            }
                   error:&error];
    require(f->cache != nil, error);
    f->cache.forceOld = reference;
    f->queue.releaseOnWait = YES;
    f->queue.gate = [device newSharedEvent];
    Ivar ivar = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    f->nativeQueue = object_getIvar(f->queue, ivar);
    require(f->nativeQueue && f->queue.gate, nil);
    f->source = (NV2AMetalTextureSource){
        .address = 32768,
        .length = format == 2 ? 64 : 256,
        .palette_address = format == 2 ? 49152 : 0,
        .palette_length = format == 2 ? 1024 : 0,
        .shape = { .format =
                       format == 0 ?
                           NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8 :
                       format == 1 ?
                           NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8 :
                           NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8,
                   .dimension = 2,
                   .width = 8,
                   .height = 8,
                   .depth = 1,
                   .levels = 1,
                   .pitch = 32 }
    };
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            unsigned i = y * 8 + x, at = format ? rtu_morton(x, y) : i;
            uint32_t word = rtu_word(i);
            if (format == 2)
                ((uint8_t *)f->ram.contents)[32768 + at] = i;
            else
                memcpy((uint8_t *)f->ram.contents + 32768 + at * 4, &word, 4);
        }
    for (unsigned i = 0; i < 256; i++) {
        uint32_t word = rtu_word(i);
        memcpy((uint8_t *)f->ram.contents + 49152 + i * 4, &word, 4);
    }
    NV2AMetalSurfaceConfig c = up_config();
    f->target = [f->cache prepareSurfaceAtAddress:8192
                                           config:&c
                                            frame:0
                                            error:&error];
    require(f->target != nil, error);
    clear_surface(f->cache, f->target, MTLClearColorMake(1, 0, 0, 1), 0, 0);
    require([f->cache submitWithError:&error] &&
                [f->cache waitUntilIdleWithError:&error],
            error);
    f->textures = [[NV2AMetalTextureCache alloc] initWithSurfaces:f->cache
                                                            error:&error];
    f->pixel = [[NV2AMetalPixelShader alloc]
        initWithDevice:device
           colorFormat:f->target.transfer.nativePixelFormat
           depthFormat:MTLPixelFormatInvalid
           sampleCount:1
                 error:&error];
    NV2AMetalDrawConfig draw = { 0 };
    draw.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                      NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                      NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                      NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
    f->raster = [[NV2AMetalDrawState alloc] initWithDevice:device
                                                    config:&draw
                                                     error:&error];
    f->query = [device newBufferWithLength:8
                                   options:MTLResourceStorageModeShared];
    require(f->textures && f->pixel && f->raster && f->query, error);
    memset(f->query.contents, 0, 8);
    return f;
}
static NV2AMetalSurfaceRecording *rtu_raster(RasterUploadFixture *f,
                                             NV2AMetalCachedTexture *texture,
                                             BOOL checkpoint, BOOL queryOnly)
{
    NSError *error = nil;
    require([f->cache beginRasterProducersWithError:&error], error);
    if (queryOnly)
        require([f->cache beginRecordingWithError:&error], error);
    else
        require([f->cache prepareSelectedSurface:f->target
                              discardingContents:NO
                                           error:&error],
                error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    if (!queryOnly) {
        pass.colorAttachments[0].texture =
            [f->target.transfer textureForCommands:f->queue error:&error];
        require(pass.colorAttachments[0].texture != nil, error);
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    }
    pass.renderTargetWidth = pass.renderTargetHeight = 4;
    if (queryOnly)
        pass.defaultRasterSampleCount = 1;
    pass.visibilityResultBuffer = f->query;
    pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    require([f->cache prepareRasterPass:pass
                                targets:queryOnly ? @[] : @[ f->target ]
                                  error:&error],
            error);
    require([f->queue addResource:f->query error:&error], error);
    id<MTL4RenderCommandEncoder> e = [f->queue beginRasterPass:pass
                                                         error:&error];
    require(e != nil, error);
    if (!texture)
        f->rasterA = f->queue.commandBuffer;
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    if (!queryOnly) {
        NV2AMetalVertex v = { 0 };
        v.clip[2] = .5f;
        v.clip[3] = 1;
        v.point_size = 1;
        float center = texture ? 2.5f : 1.5f;
        v.screen[0] = v.screen[1] = center;
        v.clip[0] = 2 * center / 4 - 1;
        v.clip[1] = 1 - 2 * center / 4;
        v.color[0][1] = v.color[0][3] = 1;
        v.texcoord[0][0] = v.texcoord[0][1] =
            texture && texture.rectangle ? .5f : .0625f;
        v.texcoord[0][3] = 1;
        id<MTLBuffer> vertices =
            [f->queue.device newBufferWithBytes:&v
                                         length:sizeof(v)
                                        options:MTLResourceStorageModeShared];
        require(vertices != nil, nil);
        NV2AMetalPixelUniforms u = { .smooth_shading = 1,
                                     .depth_format = NV2AMetalPixelDepthD24,
                                     .surface_scale = { 1, 1 },
                                     .clip_range = { 0, 16777215, 0, 16777215 },
                                     .clip_regions = { { 0, 0, 4, 4 } } };
        u.combiner.final_inputs[0] = texture ? PS_REGISTER_T0 : PS_REGISTER_V0;
        u.combiner.final_inputs[1] =
            ((texture ? PS_REGISTER_T0 : PS_REGISTER_V0) | PS_CHANNEL_ALPHA)
            << 8;
        NV2AMetalPixelTexture bindings[4] = { 0 };
        if (texture) {
            u.combiner.shader_stage_program = PS_TEXTUREMODES_PROJECT2D;
            u.textures[0].dimension = 2;
            u.textures[0].rectangle = texture.rectangle;
            u.textures[0].scale = texture.scale;
            u.textures[0].sampling = texture.binding.sampling;
            bindings[0].texture = texture.binding.texture;
            bindings[0].sampler = texture.binding.sampler;
        }
        require([f->pixel encodeVertices:vertices
                                  offset:0
                                   count:1
                               primitive:MTLPrimitiveTypePoint
                                uniforms:&u
                                textures:bindings
                                    pass:pass
                               drawState:f->raster
                             rasterClass:NV2AMetalPixelRasterDirectPoint
                    ignorePolygonCulling:NO
                           renderEncoder:e
                                commands:f->queue
                                   error:&error],
                error);
    }
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    if (!queryOnly)
        require([f->cache markWritten:f->target error:&error], error);
    NV2AMetalSurfaceRecording *token = f->cache.recording;
    [f->cache endRasterProducers];
    if (checkpoint)
        require([f->cache checkpointWithError:&error], error);
    return token;
}
static NSData *rtu_texture(id<MTLTexture> texture)
{
    NSError *error = nil;
    NV2AMetalCommands *q =
        [[NV2AMetalCommands alloc] initWithDevice:texture.device error:&error];
    require(q && [q beginWithError:&error] != nil, error);
    id<MTLBuffer> pixels = test_metal_read_texture(q, texture, 0, 0);
    require(pixels && [q submitWithError:&error] &&
                [q waitUntilIdleWithError:&error],
            error);
    NSUInteger row = (texture.width * 16 + 255) & ~(NSUInteger)255;
    NSMutableData *data = [NSMutableData new];
    for (NSUInteger y = 0; y < texture.height; y++)
        [data appendBytes:(uint8_t *)pixels.contents + y * row
                   length:texture.width * 16];
    return data;
}

static NV2AMetalSamplerConfig rtu_policy(void)
{
    return (NV2AMetalSamplerConfig){ .filter = 1 << 16 | 1 << 24,
                                     .address = 3 | 3 << 8 | 3 << 16,
                                     .anisotropy = 1 };
}
static NV2AMetalCachedTexture *rtu_upload(RasterUploadFixture *f,
                                          NSError **error)
{
    NV2AMetalSamplerConfig policy = rtu_policy();
    rtu_upload_scope = YES;
    NV2AMetalCachedTexture *t;
    @try {
        t = [f->textures prepareSource:&f->source
                               sampler:&policy
                                 frame:1
                                 error:error];
    } @finally {
        rtu_upload_scope = NO;
    }
    return t;
}
static void rtu_pixels(NSData *data, unsigned width, unsigned height,
                       BOOL final, BOOL queryOnly)
{
    assert(data.length == width * height * 4 * sizeof(float));
    const float *pixels = data.bytes;
    for (unsigned y = 0; y < height; y++)
        for (unsigned x = 0; x < width; x++) {
            float expected[4] = { 1, 0, 0, 1 };
            if (final && !queryOnly && x == 1 && y == 1) {
                expected[0] = 0;
                expected[1] = 1;
            }
            if (final && x == 2 && y == 2) {
                expected[0] = 0;
                expected[2] = 1;
            }
            if (memcmp(pixels + (y * width + x) * 4, expected,
                       sizeof(expected))) {
                fprintf(stderr,
                        "Raster upload case%u reference%u target (%u,%u) "
                        "final%u queryOnly%u: "
                        "%.8g %.8g %.8g %.8g\n",
                        rtu_case, rtu_reference, x, y, final, queryOnly,
                        pixels[(y * width + x) * 4],
                        pixels[(y * width + x) * 4 + 1],
                        pixels[(y * width + x) * 4 + 2],
                        pixels[(y * width + x) * 4 + 3]);
                abort();
            }
        }
}
static void rtu_decoded(RasterUploadFixture *f, NSData *data, unsigned format)
{
    assert(data.length == 8 * 8 * 16);
    const float *pixels = data.bytes;
    for (unsigned y = 0; y < 8; y++)
        for (unsigned x = 0; x < 8; x++) {
            unsigned at = format ? rtu_morton(x, y) : y * 8 + x;
            uint32_t word;
            if (format == 2) {
                unsigned index = ((const uint8_t *)f->ram.contents)[32768 + at];
                memcpy(&word,
                       (const uint8_t *)f->ram.contents + 49152 + index * 4, 4);
            } else
                memcpy(&word, (const uint8_t *)f->ram.contents + 32768 + at * 4,
                       4);
            float expected[] = { ((word >> 16) & 255) / 255.f,
                                 ((word >> 8) & 255) / 255.f,
                                 (word & 255) / 255.f, (word >> 24) / 255.f };
            for (unsigned lane = 0; lane < 4; lane++)
                assert(fabsf(pixels[(y * 8 + x) * 4 + lane] - expected[lane]) <
                       0.000001f);
        }
}
typedef struct RasterUploadWork {
    unsigned full, admissions, eligible, uploads;
    BOOL gateInstalled, leased, outerPreserved, producerBeforeRaster;
} RasterUploadWork;
static NSArray<NSData *> *rtu_run(id<MTLDevice> device, unsigned mode,
                                  BOOL reference, RasterUploadWork *work)
{
    NSError *error = nil;
    rtu_case = mode;
    rtu_reference = reference;
    unsigned format = mode == 1                             ? 1 :
                      (mode == 2 || mode == 7 || mode == 9) ? 2 :
                                                              0;
    BOOL queryOnly = mode == 15;
    RasterUploadFixture *f = rtu_fixture(device, format, reference);
    rtu_active = f;
    rtu_uploads = 0;
    NV2AMetalCachedTexture *warm = nil;
    if (mode == 4) {
        warm = rtu_upload(f, &error);
        require(warm && [f->cache submitWithError:&error] &&
                    [f->cache waitUntilIdleWithError:&error] &&
                    [warm validateCompletedWithError:&error],
                error);
    }
    /* These aliases are real, incompatible Surface bindings, prepared before
     * A. Their later GPU clear must be downloaded by the unchanged fallback. */
    NV2AMetalCachedSurface *alias = nil;
    if (mode == 8 || mode == 9) {
        NV2AMetalSurfaceConfig c = up_config();
        alias = [f->cache prepareSurfaceAtAddress:mode == 8 ? 32896 : 49280
                                           config:&c
                                            frame:0
                                            error:&error];
        require(alias && [f->cache submitWithError:&error] &&
                    [f->cache waitUntilIdleWithError:&error],
                error);
    }
    rtu_raster(f, nil, mode != 13 && mode != 15, queryOnly);
    assert(f->queue.hasPendingRasterPass && !f->queue.gate.signaledValue);
    id<MTLSharedEvent> escape = f->queue.gate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                     if (!escape.signaledValue)
                         escape.signaledValue = 2;
                   });
    f->queue.fullCalls = f->queue.prefixCalls = 0;
    f->cache.admissions = f->cache.eligible = 0;
    rtu_uploads = 0;
    unsigned initialNotices = f->notices;
    NSData *initialRAM =
        [NSData dataWithBytes:(uint8_t *)f->ram.contents + 32768 length:256];
    NSData *initialPalette =
        [NSData dataWithBytes:(uint8_t *)f->ram.contents + 49152 length:1024];
    if (mode == 3 || mode == 6 || mode == 7 || mode == 8 || mode == 9) {
        require([f->cache beginRasterProducersWithError:&error] &&
                    [f->cache beginRecordingWithError:&error],
                error);
        if (mode == 6 || mode == 7) {
            NSUInteger address = mode == 6 ? 32768 : 49152;
            uint64_t word;
            memcpy(&word, (uint8_t *)f->ram.contents + address, 8);
            gpu_dep_write(f->cache, address, word);
        } else if (alias) {
            require([f->cache prepareSelectedSurface:alias
                                  discardingContents:NO
                                               error:&error],
                    error);
            clear_surface(f->cache, alias, MTLClearColorMake(0, 1, 0, 1), 0, 0);
        }
        [f->cache endRasterProducers];
        if (mode != 3)
            require([f->cache checkpointWithError:&error], error);
    }
    if (mode == 12)
        require([f->cache beginRasterProducersWithError:&error], error);
    if (mode == 11)
        f->queue.forcePressure = YES; /* Explicit host-pressure simulation. */
    if (mode == 5)
        require([f->cache prepareGPUReadAtAddress:32768
                                           length:256
                                            error:&error],
                error);
    if (mode == 10) {
        rtu_fail_upload = YES;
        NV2AMetalCachedTexture *failed = rtu_upload(f, &error);
        assert(!failed && error == rtu_failure && !rtu_fail_upload);
        error = nil;
    }
    NV2AMetalCachedTexture *texture = rtu_upload(f, &error);
    require(texture != nil, error);
    if (mode == 12) {
        work->outerPreserved =
            [[f->cache valueForKey:@"rasterProducers"] boolValue];
        [f->cache endRasterProducers];
    }
    f->queue.forcePressure = NO;
    if (f->cache.recording)
        require([f->cache checkpointWithError:&error], error);
    work->full = f->queue.fullCalls;
    work->admissions = f->cache.admissions;
    work->eligible = f->cache.eligible;
    work->uploads = (unsigned)rtu_uploads;
    /* This negative CPU-write probe cannot publish a successful write. It is
     * made only for a newly captured reader, never a completed warm texture. */
    if (mode != 4)
        work->leased =
            !nv2a_metal_try_cpu_access(f->cache.cpuAccessGuard, 32768, 4, YES);
    NV2AMetalSurfaceRecording *producer = texture.producerRecording;
    require(producer &&
                [f->cache waitForProducersOfRecording:producer error:&error] &&
                [texture validateCompletedWithError:&error],
            error);
    work->producerBeforeRaster = !f->queue.gate.signaledValue &&
                                 !f->queue.gateInstalled &&
                                 producer.producersCompleted;
    NSData *decoded = rtu_texture(texture.binding.texture);
    rtu_decoded(f, decoded, format);
    if (alias)
        for (unsigned i = 0; i < 16; i++) {
            uint32_t word;
            memcpy(&word, (uint8_t *)f->ram.contents + alias.address + i * 4,
                   sizeof(word));
            assert(word == UINT32_C(0xff00ff00));
        }
    /* Independent sampling of the still-uncommitted attachment proves that
     * merely finishing the upload has not run A. */
    if (work->producerBeforeRaster)
        rtu_pixels(rtu_texture(f->target.transfer.texture), 4, 4, NO,
                   queryOnly);
    assert(f->queue.gate.signaledValue <= 1);
    work->gateInstalled = f->queue.gateInstalled;
    if (mode != 8 && mode != 9) {
        assert(
            !memcmp(initialRAM.bytes, (uint8_t *)f->ram.contents + 32768, 256));
        assert(!memcmp(initialPalette.bytes, (uint8_t *)f->ram.contents + 49152,
                       1024));
        assert(f->notices == initialNotices);
    } else
        assert(f->notices == initialNotices + 1);
    rtu_raster(f, texture, YES, NO);
    f->queue.gate.signaledValue = 1;
    require([f->cache submitWithError:&error] &&
                [f->cache waitUntilIdleWithError:&error],
            error);
    NSData *frame = rtu_texture(f->target.transfer.texture);
    rtu_pixels(frame, 4, 4, YES, queryOnly);
    uint64_t samples;
    memcpy(&samples, f->query.contents, sizeof(samples));
    assert(samples == (queryOnly ? 1 : 2));
    assert(f->target.dirty && f->queue.gate.signaledValue == 1);
    NSArray *result = @[
        decoded, frame, [NSData dataWithBytes:&samples length:sizeof(samples)],
        [NSData dataWithBytes:(uint8_t *)f->ram.contents + 32768 length:256],
        [NSData dataWithBytes:(uint8_t *)f->ram.contents + 49152 length:1024]
    ];
    rtu_active = nil;
    return result;
}
/* Invalid spans and a real completed receipt decorated with a deterministic
 * error exercise the pre-encoding boundary without inventing a driver error. */
static void rtu_errors(id<MTLDevice> device)
{
    NSError *error = nil;
    rtu_case = 14;
    rtu_reference = NO;
    RasterUploadFixture *f = rtu_fixture(device, 0, NO);
    rtu_active = f;
    rtu_raster(f, nil, YES, NO);
    unsigned before = f->queue.fullCalls;
    NV2AMetalVRAMReadPattern bad[] = { { 32768, 4, 0, 0 }, { 65535, 2, 0, 0 } };
    assert(![f->cache prepareTextureUploadReadPatterns:bad
                                                 count:2
                                                 error:&error] &&
           error);
    assert(f->queue.fullCalls == before && !f->cache.recording);
    error = nil;
    IndependentReadCommands *blocker =
        [[IndependentReadCommands alloc] initWithDevice:device error:&error];
    require(blocker != nil, error);
    gpu_dep_gate(blocker);
    require([blocker beginWithError:&error] != nil, error);
    id<MTLBuffer> marker = gpu_dep_copy(blocker, f->ram, 60000, nil, 0);
    require([blocker submitWithError:&error], error);
    rtu_dependency = blocker.lastSubmitted;
    require([f->cache beginRasterProducersWithError:&error] &&
                [f->cache beginRecordingWithError:&error] &&
                [f->queue orderAfterSubmission:rtu_dependency
                                  fromCommands:blocker
                                         error:&error],
            error);
    [f->cache endRasterProducers];
    blocker.gate.signaledValue = 1;
    require([blocker waitUntilIdleWithError:&error], error);
    assert(gpu_dep_word(marker, 0) == UINT64_C(0x3737373737373737));
    rtu_bad_dependency = YES;
    rtu_uploads = 0;
    NV2AMetalCachedTexture *texture = rtu_upload(f, &error);
    rtu_bad_dependency = NO;
    assert(!texture && error == rtu_failure && !rtu_uploads &&
           f->queue.fullCalls == before && !f->queue.gate.signaledValue);
    /* Retry keeps A's accepted checkpoint and its original native work. */
    error = nil;
    texture = rtu_upload(f, &error);
    require(texture && [f->cache checkpointWithError:&error] &&
                [f->cache waitForProducersOfRecording:texture.producerRecording
                                                error:&error] &&
                [texture validateCompletedWithError:&error],
            error);
    rtu_decoded(f, rtu_texture(texture.binding.texture), 0);
    rtu_raster(f, texture, YES, NO);
    f->queue.gate.signaledValue = 1;
    require([f->cache submitWithError:&error] &&
                [f->cache waitUntilIdleWithError:&error],
            error);
    rtu_pixels(rtu_texture(f->target.transfer.texture), 4, 4, YES, NO);
    uint64_t samples;
    memcpy(&samples, f->query.contents, 8);
    assert(samples == 2);
    rtu_dependency = nil;
    rtu_active = nil;
}
static void raster_texture_upload_tests(id<MTLDevice> device)
{
    SEL commit = @selector(commit:count:options:);
    SEL encode = @selector(encodeData:offset:palette:paletteOffset:
                           paletteLength:shape:commands:error:);
    SEL receipt = @selector(completedWithError:);
    RasterUploadFixture *probe = rtu_fixture(device, 0, NO);
    Method cm =
        class_getInstanceMethod(object_getClass(probe->nativeQueue), commit);
    Method em = class_getInstanceMethod(NV2AMetalTextureUpload.class, encode);
    Method rm = class_getInstanceMethod(NV2AMetalSubmission.class, receipt);
    assert(cm && em && rm);
    rtu_commit_original = (void *)method_getImplementation(cm);
    rtu_encode_original = (void *)method_getImplementation(em);
    rtu_receipt_original = (void *)method_getImplementation(rm);
    rtu_failure =
        [NSError errorWithDomain:@"xemu.test.raster-texture-upload"
                            code:1
                        userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"simulated native upload/dependency failure"
                        }];
    method_setImplementation(cm, (IMP)rtu_commit);
    method_setImplementation(em, (IMP)rtu_encode);
    method_setImplementation(rm, (IMP)rtu_receipt);
    @try {
        for (unsigned mode = 0; mode < 16; mode++) {
            if (mode == 14) {
                rtu_errors(device);
                continue;
            }
            @autoreleasepool {
                RasterUploadWork candidate = { 0 }, reference = { 0 };
                NSArray *actual = rtu_run(device, mode, NO, &candidate);
                NSArray *expected = rtu_run(device, mode, YES, &reference);
                if (![actual isEqual:expected]) {
                    fprintf(
                        stderr,
                        "Raster texture upload byte/query mismatch mode%u\n",
                        mode);
                    abort();
                }
                /* Work assertions deliberately follow every GPU byte oracle. */
                BOOL positive = mode <= 3 || mode == 10 || mode == 12;
                if (positive) {
                    assert(candidate.full == 0 &&
                           candidate.producerBeforeRaster &&
                           !candidate.gateInstalled && candidate.leased);
                    if (mode != 12)
                        assert(candidate.eligible && reference.full == 1 &&
                               reference.gateInstalled);
                    else
                        assert(candidate.outerPreserved &&
                               reference.outerPreserved && reference.full == 0);
                } else {
                    assert(candidate.full == 1 && reference.full == 1 &&
                           candidate.gateInstalled && reference.gateInstalled);
                }
                assert(candidate.uploads == (mode == 4  ? 0 :
                                             mode == 10 ? 2 :
                                                          1));
                assert(reference.uploads == candidate.uploads);
                if (mode == 4 || mode == 5 || mode == 12 || mode == 13 ||
                    mode == 15)
                    assert(candidate.admissions == 0 &&
                           reference.admissions == 0);
            }
        }
    } @finally {
        rtu_active = nil;
        rtu_dependency = nil;
        rtu_failure = nil;
        rtu_upload_scope = rtu_fail_upload = rtu_bad_dependency = NO;
        method_setImplementation(rm, (IMP)rtu_receipt_original);
        method_setImplementation(em, (IMP)rtu_encode_original);
        method_setImplementation(cm, (IMP)rtu_commit_original);
    }
    puts("Metal raster texture upload: 16 native groups; decoded GPU pixels, "
         "raster/query bytes and real old-route reference PASS "
         "(pressure and completed-receipt errors are host simulations)");
}
#endif
