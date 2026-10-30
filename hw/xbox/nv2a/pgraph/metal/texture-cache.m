/*
 * Native texture cache from gl/texture.c and gl/surface.c
 * Copyright (c) 2012 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2018-2025 Matt Borgerson
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */
#import "texture-cache.h"
#import "lru-cache.h"
#include "texture-cache-types.h"
#include "texture-cache-source.h"

_Static_assert(sizeof(NV2AMetalSurfaceTextureUniforms) == 16,
               "CPU/MSL surface texture capture");

static BOOL texture_cache_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.texture-cache"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

/* Immutable content identity. NSArray hashes collide for equal-length keys. */
@interface NV2AMetalTextureKey : NSObject <NSCopying> {
    uint64_t _words[20];
    NSUInteger _hash;
}
- (instancetype)initWithKeyWords:(const uint64_t *)words;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
@implementation NV2AMetalTextureKey
- (instancetype)initWithKeyWords:(const uint64_t *)words
{
    self = [super init];
    if (self) {
        memcpy(_words, words, sizeof(_words));
        const uint8_t *bytes = (const uint8_t *)_words;
        uint64_t hash = UINT64_C(14695981039346656037);
        for (NSUInteger i = 0; i < sizeof(_words); i++)
            hash = (hash ^ bytes[i]) * UINT64_C(1099511628211);
        _hash = (NSUInteger)hash;
    }
    return self;
}
- (NSUInteger)hash
{
    return _hash;
}
- (BOOL)isEqual:(id)object
{
    if (object == self)
        return YES;
    if (![object isKindOfClass:NV2AMetalTextureKey.class])
        return NO;
    return !memcmp(_words, ((NV2AMetalTextureKey *)object)->_words,
                   sizeof(_words));
}
- (id)copyWithZone:(NSZone *)zone
{
    (void)zone;
    return self;
}
@end

@interface NV2AMetalTextureContent : NSObject
@property(nonatomic) id<MTLTexture> texture;
@property(nonatomic) id<MTLBuffer> faults;
@property(nonatomic) NV2AMetalSurfaceRecording *token;
@property(nonatomic) unsigned int scale, minLevel, maxLevel;
@property(nonatomic) BOOL rectangle, signedNormalized, depth;
@property(nonatomic) BOOL mixedSignedHalf;
@property(nonatomic) BOOL validated;
/* One latest immutable binding per content; captured earlier bindings remain
 * owned by their callers even when the sampler policy changes. */
@property(nonatomic) NV2AMetalTextureBinding *binding;
@property(nonatomic) NV2AMetalSamplerConfig bindingPolicy;
@end
@implementation NV2AMetalTextureContent
@end

@interface NV2AMetalCachedTexture ()
- (instancetype)initWithContent:(NV2AMetalTextureContent *)content
                        binding:(NV2AMetalTextureBinding *)binding;
@end
@implementation NV2AMetalCachedTexture {
    NV2AMetalTextureContent *_content;
    BOOL _restored;
}
- (instancetype)initWithContent:(NV2AMetalTextureContent *)content
                        binding:(NV2AMetalTextureBinding *)binding
{
    self = [super init];
    if (self) {
        _content = content;
        _binding = binding;
        _scale = content.scale;
        _rectangle = content.rectangle;
        _signedNormalized = content.signedNormalized;
        _mixedSignedHalf = content.mixedSignedHalf;
        _depth = content.depth;
    }
    return self;
}
- (instancetype)initWithRestoredBinding:(NV2AMetalTextureBinding *)binding
                                  scale:(unsigned int)scale
                                  flags:(unsigned int)flags
{
    self = [super init];
    if (!self || !binding || !scale || scale > 16384 || (flags & ~23u) ||
        ((flags & 16) &&
         ((flags & 6) ||
          binding.texture.pixelFormat != MTLPixelFormatRGBA16Float ||
          binding.sampling.enabled != 1)))
        return nil;
    _binding = binding;
    _scale = scale;
    _rectangle = !!(flags & 1);
    _signedNormalized = !!(flags & 2);
    _depth = !!(flags & 4);
    _mixedSignedHalf = !!(flags & 16);
    _restored = YES;
    return self;
}
- (BOOL)decodeValidated
{
    return _restored || (_content.validated && _content.token.completed &&
                         !_content.token.cancelled);
}
- (BOOL)validateCompletedWithError:(NSError **)error
{
    if (self.decodeValidated)
        return YES;
    if (_content.token.cancelled || !_content.token.completed) {
        return texture_cache_error(
            error, @"Texture decode was cancelled or has not completed");
    }
    uint32_t faults;
    memcpy(&faults, _content.faults.contents, sizeof(faults));
    if (faults)
        return texture_cache_error(error, @"Native texture palette index fault");
    _content.validated = YES;
    return YES;
}
@end

/* Compare semantic fields, never padding copied from a caller's struct. */
static BOOL same_policy(const NV2AMetalSamplerConfig *a,
                        const NV2AMetalSamplerConfig *b)
{
    return a->filter == b->filter && a->address == b->address &&
           a->border_color == b->border_color &&
           a->anisotropy == b->anisotropy && a->min_level == b->min_level &&
           a->max_level == b->max_level && a->rectangle == b->rectangle &&
           a->bordered == b->bordered && a->hilo16 == b->hilo16 &&
           a->signed_channels == b->signed_channels;
}

static BOOL compatible(NV2AMetalCachedSurface *s,
                       const NV2AMetalTextureSource *source)
{
    if (!s || !s.valid || s.address != source->address) {
        return NO;
    }
    NV2AMetalSurfaceConfig c = s.transfer.config;
    NV2AMetalTextureShape t = source->shape;
    if (!c.color || t.signed_channels || t.dimension != 2 || t.cubemap ||
        t.border || t.levels != 1 || t.min_level || t.max_level ||
        c.width != t.width || c.height != t.height ||
        (!c.swizzle && c.pitch != t.pitch)) {
        return NO;
    }
    BOOL match = NO;
    unsigned bytes = 0;
    switch (c.format) {
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5:
        match = t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5;
        bytes = 2;
        break;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5:
        match = t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5 ||
                t.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R5G6B5;
        bytes = 2;
        break;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8:
        match = t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8 ||
                t.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8;
        bytes = 4;
        break;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8:
        match = t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8 ||
                t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8 ||
                t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8 ||
                t.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8;
        bytes = 4;
        break;
    default:
        break;
    }
    BOOL linear =
        t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5 ||
        t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5 ||
        t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8 ||
        t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8 ||
        t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8 ||
        t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8;
    NSUInteger length = linear ? (NSUInteger)t.pitch * t.height :
                                 (NSUInteger)t.width * t.height * bytes;
    /* Direct copies preserve texel order only when both views use the same
     * guest memory layout. Other views use GPU download and texture decode. */
    return match && c.swizzle != linear && source->length == length;
}

@interface NV2AMetalTextureCache ()
- (NV2AMetalCachedTexture *)prepareSource:(const NV2AMetalTextureSource *)source
                                  sampler:
                                      (const NV2AMetalSamplerConfig *)sampler
                                    frame:(uint64_t)frame
                             recordGPUUse:(BOOL)recordGPUUse
                                    error:(NSError **)error;
@end

@implementation NV2AMetalTextureCache {
    NV2AMetalTextureUpload *_upload;
    NV2AMetalTextureSampler *_sampler;
    id<MTLComputePipelineState> _capture;
    id<MTL4ArgumentTable> _arguments;
    NV2AMetalLRUCache<NV2AMetalTextureKey *, NV2AMetalTextureContent *>
        *_entries;
}
- (instancetype)initWithSurfaces:(NV2AMetalSurfaceCache *)surfaces
                           error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }
    if (!surfaces) {
        texture_cache_error(error,
                            @"Texture cache requires native surfaces/VRAM");
        return nil;
    }
    _surfaces = surfaces;
    id<MTLDevice> device = surfaces.commands.device;
    _upload = [[NV2AMetalTextureUpload alloc] initWithDevice:device
                                                       error:error];
    _sampler = [[NV2AMetalTextureSampler alloc] initWithDevice:device
                                                         error:error];
    id<MTL4Compiler> compiler =
        [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                    error:error];
    if (!_upload || !_sampler || !compiler) {
        return nil;
    }
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = @(metal_shader_source);
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    ld.options.mathMode = MTLMathModeSafe;
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld error:error];
    if (!library) {
        return nil;
    }
    MTL4LibraryFunctionDescriptor *fn = [MTL4LibraryFunctionDescriptor new];
    fn.library = library;
    fn.name = @"nv2a_surface_texture";
    MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
    pd.computeFunctionDescriptor = fn;
    _capture = [compiler newComputePipelineStateWithDescriptor:pd
                                           compilerTaskOptions:nil
                                                         error:error];
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 1;
    ad.maxTextureBindCount = 2;
    ad.initializeBindings = YES;
    _arguments = [device newArgumentTableWithDescriptor:ad error:error];
    if (!_capture || !_arguments) {
        return nil;
    }
    _entries = [[NV2AMetalLRUCache alloc] initWithCapacity:512];
    return self;
}
- (NSUInteger)count
{
    return _entries.count;
}
- (void)removeAllTextures
{
    [_entries removeAllObjects];
}

- (BOOL)sourceLengthForShape:(const NV2AMetalTextureShape *)shape
               paletteLength:(NSUInteger)paletteLength
                      length:(NSUInteger *)length
                       error:(NSError **)error
{
    return [_upload sourceLengthForShape:shape
                           paletteLength:paletteLength
                                  length:length
                                   error:error];
}

- (NV2AMetalTextureContent *)capture:(NV2AMetalCachedSurface *)s
                               frame:(uint64_t)frame
                              format:(unsigned int)format
                               error:(NSError **)error
{
    NV2AMetalSurfaceConfig c = s.transfer.config;
    if (![_surfaces prepareTextureRead:s error:error])
        return nil;
    s = [_surfaces prepareSurfaceAtAddress:s.address
                                    config:&c
                                     frame:frame
                                     error:error];
    if (!s) {
        return nil;
    }
    id<MTLTexture> input = s.transfer.texture;
    /* BGRA8 reads, alpha replacement and channel permutations all stay on the
     * byte lattice. Packed 5/6-bit surfaces retain Float32 capture precision.
     */
    MTLPixelFormat formatOut = input.pixelFormat == MTLPixelFormatBGRA8Unorm ?
                                  MTLPixelFormatRGBA8Unorm :
                                  MTLPixelFormatRGBA32Float;
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:formatOut
                                     width:input.width
                                    height:input.height
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLDevice> device = _surfaces.commands.device;
    id<MTLTexture> texture = [device newTextureWithDescriptor:td];
    uint32_t zero = 0;
    id<MTLBuffer> faults =
        [device newBufferWithBytes:&zero
                            length:sizeof(zero)
                           options:MTLResourceStorageModeShared];
    NV2AMetalSurfaceTextureUniforms u = {
        .width = (unsigned int)input.width,
        .height = (unsigned int)input.height,
        .channel_order =
            format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8 ? 1 :
            format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8 ? 2 :
                                                                         0,
        .force_alpha =
            c.format == NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5 ||
            c.format == NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5 ||
            c.format == NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8 ||
            c.format == NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8,
    };
    id<MTLBuffer> uniforms =
        [device newBufferWithBytes:&u
                            length:sizeof(u)
                           options:MTLResourceStorageModeShared];
    NV2AMetalCommands *commands = _surfaces.commands;
    if (!texture || !faults || !uniforms ||
        ![commands addResource:input error:error] ||
        ![commands addResource:texture error:error] ||
        ![commands addResource:uniforms error:error] ||
        ![commands keepAlive:self error:error]) {
        texture_cache_error(error, @"Cannot retain surface texture capture");
        return nil;
    }
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    if (!e) {
        texture_cache_error(error,
                            @"Cannot create surface texture capture encoder");
        return nil;
    }
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageDispatch
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setComputePipelineState:_capture];
    [_arguments setAddress:uniforms.gpuAddress atIndex:0];
    [_arguments setTexture:input.gpuResourceID atIndex:0];
    [_arguments setTexture:texture.gpuResourceID atIndex:1];
    [e setArgumentTable:_arguments];
    [e dispatchThreads:MTLSizeMake(input.width, input.height, 1)
        threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    NV2AMetalTextureContent *content = [NV2AMetalTextureContent new];
    content.texture = texture;
    content.faults = faults;
    content.scale = c.scale;
    content.token = _surfaces.recording;
    return content;
}

- (NV2AMetalCachedTexture *)prepareSource:(const NV2AMetalTextureSource *)source
                                  sampler:
                                      (const NV2AMetalSamplerConfig *)sampler
                                    frame:(uint64_t)frame
                                    error:(NSError **)error
{
    return [self prepareSource:source
                       sampler:sampler
                         frame:frame
                  recordGPUUse:YES
                         error:error];
}
- (NV2AMetalCachedTexture *)captureSource:(const NV2AMetalTextureSource *)source
                                  sampler:
                                      (const NV2AMetalSamplerConfig *)sampler
                                    frame:(uint64_t)frame
                                    error:(NSError **)error
{
    return [self prepareSource:source
                       sampler:sampler
                         frame:frame
                  recordGPUUse:NO
                         error:error];
}
- (NV2AMetalCachedTexture *)prepareSource:(const NV2AMetalTextureSource *)source
                                  sampler:
                                      (const NV2AMetalSamplerConfig *)sampler
                                    frame:(uint64_t)frame
                             recordGPUUse:(BOOL)recordGPUUse
                                    error:(NSError **)error
{
    if (!source || !sampler || !source->length) {
        texture_cache_error(error, @"Missing native texture source/sampler");
        return nil;
    }
    NV2AMetalTextureSource c = *source;
    NSUInteger sourceLength;
    if (![self sourceLengthForShape:&c.shape
                      paletteLength:c.palette_length
                             length:&sourceLength
                              error:error] ||
        c.length != sourceLength) {
        texture_cache_error(
            error, @"Native texture source length disagrees with mip layout");
        return nil;
    }
    BOOL indexed =
        c.shape.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8;
    if (!indexed) {
        c.palette_address = c.palette_length = 0;
    }
    uint64_t version, palette_version;
    if (![_surfaces sourceVersionAtAddress:c.address
                                    length:c.length
                                   version:&version
                                     error:error] ||
        ![_surfaces sourceVersionAtAddress:c.palette_address
                                    length:c.palette_length
                                   version:&palette_version
                                     error:error]) {
        return nil;
    }
    NV2AMetalCachedSurface *surface =
        [_surfaces surfaceContainingAddress:c.address];
    BOOL rtt = compatible(surface, &c);
    const uint64_t words[20] = {
        c.address,
        c.length,
        c.palette_address,
        c.palette_length,
        version,
        palette_version,
        c.shape.format,
        c.shape.dimension,
        c.shape.width,
        c.shape.height,
        c.shape.depth,
        c.shape.levels,
        c.shape.pitch,
        c.shape.min_level,
        c.shape.max_level,
        !!c.shape.cubemap,
        !!c.shape.border,
        c.shape.signed_channels,
        rtt,
        rtt ? surface.transfer.config.scale : 1,
    };
    NV2AMetalTextureKey *key =
        [[NV2AMetalTextureKey alloc] initWithKeyWords:words];
    NV2AMetalTextureContent *content = _entries[key];
    /* Cancellation invalidates the matched content, not unrelated completed
     * snapshots. Other cancelled entries remain bounded by normal LRU eviction.
     * Source versions and CPU/GPU coherence checks still run on every hit. */
    if (content.token.cancelled) {
        [_entries removeObjectForKey:key];
        content = nil;
    }
    if (!content) {
        if (rtt) {
            content = [self capture:surface
                              frame:frame
                             format:c.shape.format
                              error:error];
            if (content && ![_surfaces markRTTSampling:surface error:error])
                return nil;
            content.rectangle =
                c.shape.format ==
                    NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5 ||
                c.shape.format ==
                    NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5 ||
                c.shape.format ==
                    NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8 ||
                c.shape.format ==
                    NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8 ||
                c.shape.format ==
                    NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8 ||
                c.shape.format ==
                    NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8;
        } else if ([_surfaces prepareGPUReadAtAddress:c.address
                                               length:c.length
                                                error:error] &&
                   (!indexed ||
                    [_surfaces prepareGPUReadAtAddress:c.palette_address
                                                length:c.palette_length
                                                 error:error])) {
            NV2AMetalTextureUploadResult *upload =
                [_upload encodeData:_surfaces.vram
                             offset:c.address
                            palette:indexed ? _surfaces.vram : nil
                      paletteOffset:c.palette_address
                      paletteLength:c.palette_length
                              shape:&c.shape
                           commands:_surfaces.commands
                              error:error];
            if (upload && upload.sourceLength == c.length) {
                content = [NV2AMetalTextureContent new];
                content.texture = upload.texture;
                content.faults = upload.faults;
                content.scale = 1;
                content.minLevel = upload.minLevel;
                content.maxLevel = upload.maxLevel;
                content.rectangle = upload.rectangle;
                content.signedNormalized = upload.signedNormalized;
                content.mixedSignedHalf = upload.mixedSignedHalf;
                content.depth = upload.depth;
                content.token = _surfaces.recording;
            } else if (upload) {
                texture_cache_error(
                    error,
                    @"Native texture source length disagrees with mip layout");
            }
        }
        if (!content) {
            [_surfaces cancel];
            return nil;
        }
    } else if (!(recordGPUUse ? [_surfaces prepareGPUReadAtAddress:0
                                                            length:0
                                                             error:error] :
                                [_surfaces collectCompletedWithError:error])) {
        return nil;
    }
    NV2AMetalSamplerConfig policy = *sampler;
    policy.signed_channels = c.shape.signed_channels;
    policy.hilo16 =
        c.shape.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16 ||
        c.shape.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16;
    policy.rectangle = content.rectangle;
    policy.bordered = c.shape.border;
    policy.min_level = content.minLevel;
    policy.max_level = content.maxLevel;
    NV2AMetalSamplerConfig previousPolicy = content.bindingPolicy;
    NV2AMetalTextureBinding *binding = content.binding;
    if (!binding || !same_policy(&previousPolicy, &policy)) {
        binding = [_sampler bindingForTexture:content.texture
                                       config:&policy
                                        error:error];
        if (binding) {
            content.binding = binding;
            content.bindingPolicy = policy;
        }
    }
    NV2AMetalCachedTexture *result =
        binding ? [[NV2AMetalCachedTexture alloc] initWithContent:content
                                                          binding:binding] :
                  nil;
    if (!result ||
        (content.token.completed &&
         ![result validateCompletedWithError:error]) ||
        (recordGPUUse && ![_surfaces.commands addResource:binding.texture
                                                    error:error])) {
        [_surfaces cancel];
        [_entries removeObjectForKey:key];
        return nil;
    }
    _entries[key] = content;
    return result;
}
@end
