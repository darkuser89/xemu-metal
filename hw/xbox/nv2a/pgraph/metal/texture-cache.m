/*
 * Native texture cache from gl/texture.c and gl/surface.c
 * Copyright (c) 2012 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2018-2025 Matt Borgerson
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */
#import "texture-cache.h"
#import "lru-cache.h"
#import "texture-storage.h"
#import "shader-library.h"
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

/* A null initializer input creates an encoding-thread lookup key. Copying it
 * freezes the current words for storage. Stored keys are immutable. */
@interface NV2AMetalTextureKey : NSObject <NSCopying> {
    uint64_t _words[20];
    NSUInteger _hash;
    BOOL _lookup;
}
- (instancetype)initWithKeyWords:(const uint64_t *)words;
- (void)setLookupWords:(const uint64_t *)words;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
@implementation NV2AMetalTextureKey
- (void)loadWords:(const uint64_t *)words
{
    memcpy(_words, words, sizeof(_words));
    const uint8_t *bytes = (const uint8_t *)_words;
    uint64_t hash = UINT64_C(14695981039346656037);
    for (NSUInteger i = 0; i < sizeof(_words); i++)
        hash = (hash ^ bytes[i]) * UINT64_C(1099511628211);
    _hash = (NSUInteger)hash;
}

- (instancetype)initWithKeyWords:(const uint64_t *)words
{
    static const uint64_t emptyWords[20];
    self = [super init];
    if (self) {
        _lookup = !words;
        [self loadWords:words ? words : emptyWords];
    }
    return self;
}
- (void)setLookupWords:(const uint64_t *)words
{
    NSAssert(_lookup, @"Stored texture keys are immutable");
    if (memcmp(_words, words, sizeof(_words)))
        [self loadWords:words];
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
    return _lookup ?
        [[NV2AMetalTextureKey alloc] initWithKeyWords:_words] : self;
}
@end

@interface NV2AMetalTextureContent : NSObject
@property(nonatomic) id<MTLTexture> texture;
/* Surface captures have no palette decoder and leave this unset. */
@property(nonatomic) id<MTLBuffer> faults;
@property(nonatomic) NV2AMetalSurfaceRecording *token;
@property(nonatomic) unsigned int scale, minLevel, maxLevel;
@property(nonatomic) BOOL rectangle, signedNormalized, depth;
@property(nonatomic) BOOL mixedSignedHalf;
@property(nonatomic) BOOL validated;
@end
@implementation NV2AMetalTextureContent
@end

@interface NV2AMetalCachedTexture ()
@property(nonatomic, readonly) NV2AMetalTextureContent *content;
- (instancetype)initWithContent:(NV2AMetalTextureContent *)content
                        binding:(NV2AMetalTextureBinding *)binding
                         policy:(const NV2AMetalSamplerConfig *)policy;
- (BOOL)matchesPolicy:(const NV2AMetalSamplerConfig *)policy;
@end
@implementation NV2AMetalCachedTexture {
    NV2AMetalSamplerConfig _policy;
    BOOL _restored;
}
- (instancetype)initWithContent:(NV2AMetalTextureContent *)content
                        binding:(NV2AMetalTextureBinding *)binding
                         policy:(const NV2AMetalSamplerConfig *)policy
{
    self = [super init];
    if (self) {
        _content = content;
        _binding = binding;
        _policy = *policy;
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
/* Compare semantic fields, never padding copied from a caller's struct. */
- (BOOL)matchesPolicy:(const NV2AMetalSamplerConfig *)policy
{
    return _policy.filter == policy->filter &&
           _policy.address == policy->address &&
           _policy.border_color == policy->border_color &&
           _policy.anisotropy == policy->anisotropy &&
           _policy.min_level == policy->min_level &&
           _policy.max_level == policy->max_level &&
           _policy.rectangle == policy->rectangle &&
           _policy.bordered == policy->bordered &&
           _policy.hilo16 == policy->hilo16 &&
           _policy.signed_channels == policy->signed_channels;
}
- (BOOL)decodeValidated
{
    return _restored || (_content.validated && _content.token.producersCompleted &&
                         !_content.token.cancelled);
}
- (NV2AMetalSurfaceRecording *)producerRecording
{
    return _content.token;
}
- (BOOL)validateCompletedWithError:(NSError **)error
{
    if (self.decodeValidated)
        return YES;
    if (_content.token.cancelled || !_content.token.producersCompleted) {
        return texture_cache_error(
            error, @"Texture decode was cancelled or has not completed");
    }
    uint32_t faults = 0;
    if (_content.faults)
        memcpy(&faults, _content.faults.contents, sizeof(faults));
    if (faults)
        return texture_cache_error(error, @"Native texture palette index fault");
    _content.validated = YES;
    return YES;
}
@end

/* A live upload still owns exact VRAM reader ranges. Keep only small raw
 * sources, and never extend a texture's GPU lifetime through this index. */
enum { NV2AMetalTextureComparisonBytes = 64 * 1024 };
@interface NV2AMetalTextureComparison : NSObject
@property(nonatomic, weak) NV2AMetalCachedTexture *texture;
@property(nonatomic) NSData *source, *palette;
@end
@implementation NV2AMetalTextureComparison
@end

/* These views reinterpret the same one/two guest bytes. The capture keeps
 * their address order; immutable Metal read swizzles supply logical RGBA. */
static unsigned rtt_byte_storage(unsigned surface, unsigned format)
{
    if (surface == NV097_SET_SURFACE_FORMAT_COLOR_LE_B8) {
        switch (format) {
        case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8:
        case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8:
            return NV2AMetalTextureStorageByteY8;
        case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_AY8:
        case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_AY8:
            return NV2AMetalTextureStorageByteAY8;
        case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8:
        case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8:
            return NV2AMetalTextureStorageByteA8;
        }
    } else if (surface == NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8) {
        switch (format) {
        case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8Y8:
        case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8Y8:
            return NV2AMetalTextureStorageByteA8Y8;
        case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_G8B8:
        case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_G8B8:
            return NV2AMetalTextureStorageByteG8B8;
        case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8B8:
            return NV2AMetalTextureStorageByteR8B8;
        }
    }
    return NV2AMetalTextureStorageFloat32;
}

static BOOL rtt_linear_format(unsigned format)
{
    return format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5 ||
           format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5 ||
           format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5 ||
           format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8 ||
           format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8 ||
           format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8 ||
           format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8 ||
           format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8 ||
           format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8 ||
           format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_AY8 ||
           format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8 ||
           format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8Y8 ||
           format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_G8B8;
}

static unsigned rtt_swizzled_channel_order(unsigned format)
{
    switch (format) {
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8:
        return 1;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8:
        return 2;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8:
        return 3;
    default:
        return 0;
    }
}

static BOOL compatible(NV2AMetalCachedSurface *s,
                       const NV2AMetalTextureSource *source,
                       BOOL downsampleOpaque, BOOL swizzledChannels,
                       BOOL packed1555)
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
        match =
            t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5 ||
            (packed1555 &&
             (t.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5 ||
              t.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A1R5G5B5 ||
              t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5));
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
        match =
            t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8 ||
            t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8 ||
            t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8 ||
            t.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8 ||
            (swizzledChannels &&
             (t.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8 ||
              t.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8 ||
              t.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8 ||
              t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8)) ||
            ((c.scale == 1 || downsampleOpaque) &&
             (t.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8 ||
              t.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8));
        bytes = 4;
        break;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8:
        bytes = c.format == NV097_SET_SURFACE_FORMAT_COLOR_LE_B8 ? 1 : 2;
        match = rtt_byte_storage(c.format, t.format) !=
                NV2AMetalTextureStorageFloat32;
        break;
    default:
        break;
    }
    BOOL linear = rtt_linear_format(t.format);
    NSUInteger length = linear ? (NSUInteger)t.pitch * t.height :
                                 (NSUInteger)t.width * t.height * bytes;
    /* Direct copies preserve texel order only when both views use the same
     * guest memory layout. Other views use GPU download and texture decode. */
    return match && c.swizzle != linear && source->length == length;
}

static unsigned rtt_storage(NV2AMetalCachedSurface *surface, unsigned format)
{
    NV2AMetalSurfaceTransfer *transfer = surface.transfer;
    MTLPixelFormat pixelFormat = transfer.nativePixelFormat;
    MTLTextureSwizzleChannels swizzle = transfer.nativeSwizzle;
    if (swizzle.red != MTLTextureSwizzleRed ||
        swizzle.green != MTLTextureSwizzleGreen ||
        swizzle.blue != MTLTextureSwizzleBlue ||
        swizzle.alpha != MTLTextureSwizzleAlpha)
        return NV2AMetalTextureStorageFloat32;
    unsigned surfaceFormat = surface.transfer.config.format;
    if ((pixelFormat == MTLPixelFormatR8Unorm &&
         surfaceFormat == NV097_SET_SURFACE_FORMAT_COLOR_LE_B8) ||
        (pixelFormat == MTLPixelFormatRG8Unorm &&
         surfaceFormat == NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8))
        return rtt_byte_storage(surfaceFormat, format);
    if (pixelFormat == MTLPixelFormatB5G6R5Unorm &&
        surfaceFormat == NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5)
        return NV2AMetalTextureStoragePackedR565;
    if (pixelFormat == MTLPixelFormatBGR5A1Unorm &&
        (surfaceFormat == NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5 ||
         surfaceFormat == NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5))
        return format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A1R5G5B5 ||
                       format ==
                           NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5 ?
                   NV2AMetalTextureStoragePackedA1555 :
                   NV2AMetalTextureStoragePackedX1555;
    if (pixelFormat != MTLPixelFormatBGRA8Unorm)
        return NV2AMetalTextureStorageFloat32;
    if (format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8 ||
        format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8)
        return NV2AMetalTextureStorageBGRX8;
    if (format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8 ||
        format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8)
        return NV2AMetalTextureStorageBGRA8SwapRB;
    if (format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8 ||
        format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8)
        return NV2AMetalTextureStorageBGRA8ARGB;
    return NV2AMetalTextureStorageBGRA8;
}

@interface NV2AMetalTextureCache ()
- (NV2AMetalCachedTexture *)prepareSource:(const NV2AMetalTextureSource *)source
                                  sampler:
                                      (const NV2AMetalSamplerConfig *)sampler
                                    frame:(uint64_t)frame
                        collectedFeedback:(BOOL *)collectedFeedback
                                    error:(NSError **)error;
@end

@implementation NV2AMetalTextureCache {
    NV2AMetalTextureUpload *_upload;
    NV2AMetalTextureSampler *_sampler;
    NV2AMetalShaderLibrary *_module;
    id<MTLComputePipelineState> _capture;
    id<MTL4ArgumentTable> _arguments;
    id<MTLComputePipelineState> _downsampleCapture;
    id<MTL4ArgumentTable> _downsampleArguments;
    id<MTLComputePipelineState> _downsampleChannelsCapture;
    id<MTL4ArgumentTable> _downsampleChannelsArguments;
    NV2AMetalTextureKey *_lookupKey;
    NV2AMetalLRUCache<NV2AMetalTextureKey *, NV2AMetalCachedTexture *>
        *_entries;
    /* At most 4 MiB of raw comparison bytes, separate from GPU content. */
    NV2AMetalLRUCache<NV2AMetalTextureKey *, NV2AMetalTextureComparison *>
        *_comparisons;
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
    if (!_upload || !_sampler)
        return nil;
    _lookupKey = [[NV2AMetalTextureKey alloc] initWithKeyWords:NULL];
    _entries = [[NV2AMetalLRUCache alloc] initWithCapacity:512];
    return self;
}
- (NV2AMetalShaderLibrary *)shaderModuleWithError:(NSError **)error
{
    if (!_module) {
        _module = [NV2AMetalShaderLibrary
            sharedWithDevice:_surfaces.commands.device
                      source:metal_shader_source
                       error:error];
    }
    return _module;
}
- (BOOL)prepareCaptureWithError:(NSError **)error
{
    if (_capture)
        return YES;
    NV2AMetalShaderLibrary *module = [self shaderModuleWithError:error];
    if (!module)
        return NO;
    id<MTLComputePipelineState> capture =
        [module computeFunction:@"nv2a_surface_texture" error:error];
    if (!capture)
        return NO;
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 1;
    ad.maxTextureBindCount = 2;
    ad.initializeBindings = YES;
    id<MTL4ArgumentTable> arguments =
        [device newArgumentTableWithDescriptor:ad error:error];
    if (!arguments)
        return NO;
    _capture = capture;
    _arguments = arguments;
    return YES;
}
/* The scaled A8/A7 -> X8 case needs the old RAM downsample semantics.
 * The remaining source/layout checks still belong to compatible(). */
- (BOOL)canCaptureDownsampledOpaqueSurface:(NV2AMetalCachedSurface *)surface
                                    format:(unsigned)format
{
    if (!surface.valid ||
        (format != NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8 &&
         format != NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8))
        return NO;
    NV2AMetalSurfaceTransfer *transfer = surface.transfer;
    NV2AMetalSurfaceConfig c = transfer.config;
    if (!c.color || c.scale <= 1 || !c.width || !c.height ||
        (c.format != NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8 &&
         c.format != NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8 &&
         c.format != NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8) ||
        transfer.nativePixelFormat != MTLPixelFormatBGRA8Unorm ||
        c.width > NSUIntegerMax / c.scale ||
        c.height > NSUIntegerMax / c.scale ||
        transfer.nativeWidth != (NSUInteger)c.width * c.scale ||
        transfer.nativeHeight != (NSUInteger)c.height * c.scale)
        return NO;
    MTLTextureSwizzleChannels swizzle = transfer.nativeSwizzle;
    return swizzle.red == MTLTextureSwizzleRed &&
           swizzle.green == MTLTextureSwizzleGreen &&
           swizzle.blue == MTLTextureSwizzleBlue &&
           swizzle.alpha == MTLTextureSwizzleAlpha;
}

- (BOOL)prepareDownsampleCaptureWithError:(NSError **)error
{
    if (_downsampleCapture)
        return YES;
    NV2AMetalShaderLibrary *module = [self shaderModuleWithError:error];
    if (!module)
        return NO;
    id<MTLComputePipelineState> pipeline =
        [module computeFunction:@"nv2a_surface_texture_downsample_opaque"
                          error:error];
    if (!pipeline)
        return NO;
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 1;
    ad.maxTextureBindCount = 2;
    ad.initializeBindings = YES;
    id<MTL4ArgumentTable> arguments =
        [device newArgumentTableWithDescriptor:ad error:error];
    if (!arguments)
        return NO;
    _downsampleCapture = pipeline;
    _downsampleArguments = arguments;
    return YES;
}

- (NV2AMetalTextureContent *)captureDownsampledOpaque:
                                 (NV2AMetalCachedSurface *)surface
                                                frame:(uint64_t)frame
                                               format:(unsigned)format
                                                error:(NSError **)error
{
    surface = [_surfaces prepareSurfaceForRTTSnapshot:surface
                                                frame:frame
                                                error:error];
    if (!surface)
        return nil;
    if (![self canCaptureDownsampledOpaqueSurface:surface format:format]) {
        texture_cache_error(error, @"Invalid scaled opaque surface capture");
        return nil;
    }
    NV2AMetalSurfaceConfig c = surface.transfer.config;
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:c.width
                                    height:c.height
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    /* Writable textures require identity swizzles. The kernel writes opaque
     * alpha into every texel, preserving X8 reads and portable snapshots. */
    NV2AMetalCommands *commands = _surfaces.commands;
    id<MTLTexture> texture = [commands.device newTextureWithDescriptor:td];
    if (!texture) {
        texture_cache_error(error, @"Cannot allocate scaled surface capture");
        return nil;
    }
    const NV2AMetalSurfaceTextureUniforms u = {
        .width = c.width,
        .height = c.height,
    };
    NSUInteger offset = 0;
    id<MTLBuffer> uniforms = [commands uploadBytes:&u
                                            length:sizeof(u)
                                            offset:&offset
                                             error:error];
    id<MTLTexture> source =
        uniforms ? [surface.transfer textureForCommands:commands error:error] :
                   nil;
    if (!source || ![commands addResource:source error:error] ||
        ![commands addResource:texture error:error] ||
        ![commands keepAlive:self error:error])
        return nil;
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        texture_cache_error(error,
                            @"Cannot create scaled surface capture encoder");
        return nil;
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageDispatch
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder setComputePipelineState:_downsampleCapture];
    [_downsampleArguments setAddress:uniforms.gpuAddress + offset atIndex:0];
    [_downsampleArguments setTexture:source.gpuResourceID atIndex:0];
    [_downsampleArguments setTexture:texture.gpuResourceID atIndex:1];
    [encoder setArgumentTable:_downsampleArguments];
    [encoder dispatchThreads:MTLSizeMake(c.width, c.height, 1)
        threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [encoder barrierAfterStages:MTLStageAll
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    if (![_surfaces markRTTSnapshotCaptured:surface error:error])
        return nil;
    NV2AMetalTextureContent *content = [NV2AMetalTextureContent new];
    content.texture = texture;
    content.scale = 1;
    content.token = _surfaces.recording;
    return content;
}

/* The first two SZ channel orders can retain scale-one source bytes with an
 * immutable read swizzle. Other cases reproduce the old download's logical
 * texel selection, including all eight stored alpha bits of A7 surfaces. */
- (BOOL)canCaptureSwizzledChannelsSurface:(NV2AMetalCachedSurface *)surface
                                   format:(unsigned)format
{
    if (!surface.valid || !rtt_swizzled_channel_order(format))
        return NO;
    NV2AMetalSurfaceTransfer *transfer = surface.transfer;
    NV2AMetalSurfaceConfig c = transfer.config;
    BOOL linear = format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8;
    if (!c.color || c.swizzle == linear || !c.scale || !c.width || !c.height ||
        (c.format != NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8 &&
         c.format != NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8 &&
         c.format != NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8) ||
        transfer.nativePixelFormat != MTLPixelFormatBGRA8Unorm ||
        c.width > NSUIntegerMax / c.scale ||
        c.height > NSUIntegerMax / c.scale ||
        transfer.nativeWidth != (NSUInteger)c.width * c.scale ||
        transfer.nativeHeight != (NSUInteger)c.height * c.scale)
        return NO;
    MTLTextureSwizzleChannels swizzle = transfer.nativeSwizzle;
    return swizzle.red == MTLTextureSwizzleRed &&
           swizzle.green == MTLTextureSwizzleGreen &&
           swizzle.blue == MTLTextureSwizzleBlue &&
           swizzle.alpha == MTLTextureSwizzleAlpha;
}

- (BOOL)prepareDownsampleChannelsCaptureWithError:(NSError **)error
{
    if (_downsampleChannelsCapture)
        return YES;
    NV2AMetalShaderLibrary *module = [self shaderModuleWithError:error];
    if (!module)
        return NO;
    id<MTLComputePipelineState> pipeline =
        [module computeFunction:@"nv2a_surface_texture_downsample_channels"
                          error:error];
    if (!pipeline)
        return NO;
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 1;
    ad.maxTextureBindCount = 2;
    ad.initializeBindings = YES;
    id<MTL4ArgumentTable> arguments =
        [device newArgumentTableWithDescriptor:ad error:error];
    if (!arguments)
        return NO;
    _downsampleChannelsCapture = pipeline;
    _downsampleChannelsArguments = arguments;
    return YES;
}

- (NV2AMetalTextureContent *)captureDownsampledChannels:
                                 (NV2AMetalCachedSurface *)surface
                                                  frame:(uint64_t)frame
                                                 format:(unsigned)format
                                                  error:(NSError **)error
{
    surface = [_surfaces prepareSurfaceForRTTSnapshot:surface
                                                frame:frame
                                                error:error];
    if (!surface)
        return nil;
    unsigned order = rtt_swizzled_channel_order(format);
    if (![self canCaptureSwizzledChannelsSurface:surface format:format] ||
        (surface.transfer.config.scale == 1 && order != 3)) {
        texture_cache_error(error, @"Invalid scaled channel surface capture");
        return nil;
    }
    NV2AMetalSurfaceConfig c = surface.transfer.config;
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:c.width
                                    height:c.height
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    /* Shader-write targets require identity swizzles. Store the logical
     * channel order directly so snapshots need no new storage type. */
    NV2AMetalCommands *commands = _surfaces.commands;
    id<MTLTexture> texture = [commands.device newTextureWithDescriptor:td];
    if (!texture) {
        texture_cache_error(error,
                            @"Cannot allocate scaled channel surface capture");
        return nil;
    }
    const NV2AMetalSurfaceTextureUniforms u = {
        .width = c.width,
        .height = c.height,
        .channel_order = order,
    };
    NSUInteger offset = 0;
    id<MTLBuffer> uniforms = [commands uploadBytes:&u
                                            length:sizeof(u)
                                            offset:&offset
                                             error:error];
    id<MTLTexture> source =
        uniforms ? [surface.transfer textureForCommands:commands error:error] :
                   nil;
    if (!source || ![commands addResource:source error:error] ||
        ![commands addResource:texture error:error] ||
        ![commands keepAlive:self error:error])
        return nil;
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        texture_cache_error(error,
                            @"Cannot create scaled channel capture encoder");
        return nil;
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageDispatch
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder setComputePipelineState:_downsampleChannelsCapture];
    [_downsampleChannelsArguments setAddress:uniforms.gpuAddress + offset
                                     atIndex:0];
    [_downsampleChannelsArguments setTexture:source.gpuResourceID atIndex:0];
    [_downsampleChannelsArguments setTexture:texture.gpuResourceID atIndex:1];
    [encoder setArgumentTable:_downsampleChannelsArguments];
    [encoder dispatchThreads:MTLSizeMake(c.width, c.height, 1)
        threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [encoder barrierAfterStages:MTLStageAll
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    if (![_surfaces markRTTSnapshotCaptured:surface error:error])
        return nil;
    NV2AMetalTextureContent *content = [NV2AMetalTextureContent new];
    content.texture = texture;
    content.scale = 1;
    content.token = _surfaces.recording;
    return content;
}

- (NSUInteger)count
{
    return _entries.count;
}
- (void)removeAllTextures
{
    [_entries removeAllObjects];
    [_comparisons removeAllObjects];
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

/* These three guest views share the source's exact packed two-byte words.
 * Only the new scaled path needs a bounded linear result for its final blit;
 * existing LU X1555 captures retain their high-resolution representation. */
- (BOOL)canCapturePacked1555Surface:(NV2AMetalCachedSurface *)surface
                             format:(unsigned)format
{
    if (!surface.valid ||
        (format != NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5 &&
         format != NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A1R5G5B5 &&
         format != NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5))
        return NO;
    NV2AMetalSurfaceTransfer *transfer = surface.transfer;
    NV2AMetalSurfaceConfig c = transfer.config;
    MTLTextureSwizzleChannels swizzle = transfer.nativeSwizzle;
    BOOL linear = format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5;
    if (!c.color || c.swizzle == linear ||
        (c.format != NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5 &&
         c.format != NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5) ||
        transfer.nativePixelFormat != MTLPixelFormatBGR5A1Unorm ||
        swizzle.red != MTLTextureSwizzleRed ||
        swizzle.green != MTLTextureSwizzleGreen ||
        swizzle.blue != MTLTextureSwizzleBlue ||
        swizzle.alpha != MTLTextureSwizzleAlpha || !c.width || !c.height ||
        !c.scale || c.width > UINT32_MAX / c.scale ||
        c.height > UINT32_MAX / c.scale ||
        transfer.nativeWidth != (NSUInteger)c.width * c.scale ||
        transfer.nativeHeight != (NSUInteger)c.height * c.scale)
        return NO;
    if (c.scale > 1) {
        /* SurfaceTransfer writes its original guest pitch. The final raw
         * buffer-to-texture blit has the same even/pixel-width pitch limits
         * as the existing direct surface-copy path. */
        uint64_t span =
            (uint64_t)(c.height - 1) * c.pitch + (uint64_t)c.width * 2;
        if (c.width > UINT32_MAX / 2 || c.pitch < c.width * 2 ||
            (c.pitch & 1) || c.pitch > 16384u * 2 || span > UINT32_MAX ||
            span > _surfaces.commands.device.maxBufferLength)
            return NO;
    }
    return YES;
}

- (NV2AMetalTextureContent *)captureDownsampledPacked1555:
                                 (NV2AMetalCachedSurface *)surface
                                                    frame:(uint64_t)frame
                                                   format:(unsigned)format
                                                    error:(NSError **)error
{
    surface = [_surfaces prepareSurfaceForRTTSnapshot:surface
                                                frame:frame
                                                error:error];
    if (!surface)
        return nil;
    if (![self canCapturePacked1555Surface:surface format:format] ||
        surface.transfer.config.scale <= 1) {
        texture_cache_error(error, @"Invalid scaled packed surface capture");
        return nil;
    }
    NV2AMetalSurfaceConfig c = surface.transfer.config;
    unsigned storage = rtt_storage(surface, format);
    NV2AMetalCommands *commands = _surfaces.commands;
    NSUInteger length =
        (NSUInteger)(c.height - 1) * c.pitch + (NSUInteger)c.width * 2;
    /* Never borrow orderedTransferScratch here: encodeDownload uses that
     * scratch for the distinct, full-resolution raw source staging. */
    id<MTLBuffer> result =
        [commands.device newBufferWithLength:length
                                     options:MTLResourceStorageModePrivate];
    if (!result) {
        texture_cache_error(error, @"Cannot allocate packed surface result");
        return nil;
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:nv2a_metal_texture_storage_format(
                                               storage)
                                     width:c.width
                                    height:c.height
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead;
    td.swizzle = nv2a_metal_texture_storage_swizzle(storage);
    id<MTLTexture> texture = [commands.device newTextureWithDescriptor:td];
    if (!texture) {
        texture_cache_error(error, @"Cannot allocate packed surface capture");
        return nil;
    }
    if (![commands addResource:result error:error] ||
        ![commands addResource:texture error:error] ||
        ![surface.transfer encodeDownloadToBuffer:result
                                           offset:0
                                          swizzle:NO
                                             flip:NO
                                        downscale:YES
                                         commands:commands
                                            error:error])
        return nil;
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        texture_cache_error(error,
                            @"Cannot create packed surface capture encoder");
        return nil;
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromBuffer:result
               sourceOffset:0
          sourceBytesPerRow:c.pitch
        sourceBytesPerImage:0
                 sourceSize:MTLSizeMake(c.width, c.height, 1)
                  toTexture:texture
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    if (![_surfaces markRTTSnapshotCaptured:surface error:error])
        return nil;
    NV2AMetalTextureContent *content = [NV2AMetalTextureContent new];
    content.texture = texture;
    content.scale = 1;
    content.token = _surfaces.recording;
    return content;
}

- (NV2AMetalTextureContent *)capture:(NV2AMetalCachedSurface *)s
                               frame:(uint64_t)frame
                              format:(unsigned int)format
                               error:(NSError **)error
{
    unsigned storage = rtt_storage(s, format);
    BOOL direct = storage != NV2AMetalTextureStorageFloat32;
    NV2AMetalSurfaceConfig c = s.transfer.config;
    s = [_surfaces prepareSurfaceForRTTSnapshot:s frame:frame error:error];
    if (!s) {
        return nil;
    }
    MTLPixelFormat inputFormat = s.transfer.nativePixelFormat;
    NSUInteger inputWidth = s.transfer.nativeWidth,
               inputHeight = s.transfer.nativeHeight;
    /* Copy compatible surfaces without sampling or conversion. The immutable
     * read swizzle applies alpha replacement/channel order and survives
     * snapshots. Packed formats keep the source's native read precision. */
    MTLPixelFormat formatOut =
        direct ? nv2a_metal_texture_storage_format(storage) :
        inputFormat == MTLPixelFormatBGRA8Unorm ? MTLPixelFormatRGBA8Unorm :
                                                  MTLPixelFormatRGBA32Float;
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formatOut
                                                           width:inputWidth
                                                          height:inputHeight
                                                       mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage =
        MTLTextureUsageShaderRead | (direct ? 0 : MTLTextureUsageShaderWrite);
    if (direct)
        td.swizzle = nv2a_metal_texture_storage_swizzle(storage);
    NV2AMetalCommands *commands = _surfaces.commands;
    id<MTLTexture> texture = [commands.device newTextureWithDescriptor:td];
    if (!texture) {
        texture_cache_error(error, @"Cannot allocate surface texture capture");
        return nil;
    }
    NV2AMetalSurfaceTextureUniforms u = {
        .width = (unsigned int)inputWidth,
        .height = (unsigned int)inputHeight,
        .channel_order =
            (format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8 ||
             format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8) ?
                1 :
            (format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8 ||
             format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8) ?
                2 :
                0,
        .force_alpha =
            c.format == NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5 ||
            c.format == NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5 ||
            c.format == NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8 ||
            c.format == NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8,
    };
    NSUInteger uniformOffset = 0;
    id<MTLBuffer> uniforms = direct ? nil :
                                      [commands uploadBytes:&u
                                                     length:sizeof(u)
                                                     offset:&uniformOffset
                                                      error:error];
    if (!direct && !uniforms)
        return nil;
    id<MTLTexture> input = [s.transfer textureForCommands:commands error:error];
    if (!input || ![commands addResource:input error:error] ||
        ![commands addResource:texture error:error] ||
        (!direct && ![commands keepAlive:self error:error]))
        return nil;
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    if (!e) {
        texture_cache_error(error,
                            @"Cannot create surface texture capture encoder");
        return nil;
    }
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:direct ? MTLStageBlit : MTLStageDispatch
             visibilityOptions:MTL4VisibilityOptionDevice];
    if (direct) {
        [e copyFromTexture:input sourceSlice:0 sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(input.width, input.height, 1)
                     toTexture:texture destinationSlice:0 destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
    } else {
        [e setComputePipelineState:_capture];
        [_arguments setAddress:uniforms.gpuAddress + uniformOffset atIndex:0];
        [_arguments setTexture:input.gpuResourceID atIndex:0];
        [_arguments setTexture:texture.gpuResourceID atIndex:1];
        [e setArgumentTable:_arguments];
        [e dispatchThreads:MTLSizeMake(input.width, input.height, 1)
            threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    }
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    if (![_surfaces markRTTSnapshotCaptured:s error:error])
        return nil;
    NV2AMetalTextureContent *content = [NV2AMetalTextureContent new];
    content.texture = texture;
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
             collectedFeedback:NULL
                         error:error];
}
- (NV2AMetalCachedTexture *)captureSource:(const NV2AMetalTextureSource *)source
                                  sampler:
                                      (const NV2AMetalSamplerConfig *)sampler
                                    frame:(uint64_t)frame
                        collectedFeedback:(BOOL *)collectedFeedback
                                    error:(NSError **)error
{
    return [self prepareSource:source
                       sampler:sampler
                         frame:frame
             collectedFeedback:collectedFeedback
                         error:error];
}
- (NV2AMetalCachedTexture *)prepareSource:(const NV2AMetalTextureSource *)source
                                  sampler:
                                      (const NV2AMetalSamplerConfig *)sampler
                                    frame:(uint64_t)frame
                        collectedFeedback:(BOOL *)collectedFeedback
                                    error:(NSError **)error
{
    BOOL recordGPUUse = !collectedFeedback;
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
    const NV2AMetalVRAMReadSpan sources[] = {
        { .address = c.address, .length = c.length },
        { .address = c.palette_address, .length = c.palette_length },
    };
    uint64_t versions[2] = { 0 };
    NV2AMetalCachedSurface *surface = nil;
    if (![_surfaces sourceVersionsForReadSpans:sources
                                         count:indexed ? 2 : 1
                                      versions:versions
                                  firstSurface:&surface
                                         error:error]) {
        return nil;
    }
    BOOL downsampleOpaque =
        [self canCaptureDownsampledOpaqueSurface:surface format:c.shape.format];
    BOOL swizzledChannels =
        [self canCaptureSwizzledChannelsSurface:surface format:c.shape.format];
    BOOL packed1555 = [self canCapturePacked1555Surface:surface
                                                 format:c.shape.format];
    BOOL rtt =
        compatible(surface, &c, downsampleOpaque, swizzledChannels, packed1555);
    const uint64_t words[20] = {
        c.address,
        c.length,
        c.palette_address,
        c.palette_length,
        versions[0],
        versions[1],
        c.shape.format,
        c.shape.dimension,
        c.shape.width,
        c.shape.height,
        c.shape.depth,
        c.shape.levels,
        c.shape.pitch,
        /* Mip clamps select a sampler view; the level count above fixes the
         * decoded image data and source length. */
        0,
        0,
        !!c.shape.cubemap,
        !!c.shape.border,
        c.shape.signed_channels,
        rtt,
        rtt ? surface.transfer.config.scale : 1,
    };
    NV2AMetalTextureKey *key = _lookupKey;
    [key setLookupWords:words];
    NV2AMetalCachedTexture *previous = _entries[key];
    NV2AMetalTextureContent *content = previous.content;
    /* Cancellation invalidates the matched content, not unrelated completed
     * snapshots. Other cancelled entries remain bounded by normal LRU eviction.
     * Source versions and CPU/GPU coherence checks still run on every hit. */
    if (content.token.cancelled) {
        [_entries removeObjectForKey:key];
        previous = nil;
        content = nil;
    }
    BOOL compareSource = !content && !rtt && _surfaces.willWatchVRAM &&
        c.length <= NV2AMetalTextureComparisonBytes &&
        c.palette_length <= NV2AMetalTextureComparisonBytes - c.length;
    uint64_t comparisonWords[20];
    NV2AMetalTextureComparison *comparison = nil;
    BOOL reusedContent = NO, uploaded = NO;
    if (compareSource) {
        memcpy(comparisonWords, words, sizeof(words));
        comparisonWords[4] = comparisonWords[5] = 0;
        if (!content && _comparisons) {
            [key setLookupWords:comparisonWords];
            comparison = _comparisons[key];
            NV2AMetalCachedTexture *candidate = comparison.texture;
            NV2AMetalSurfaceRecording *token = candidate.producerRecording;
            /* Hazard retirement releases the CPU write guards, even when the
             * recording remains open. Do not acquire a new guard
             * here: a prior CPU pre-write callback may already have returned.
             */
            if (!token || token.cancelled || token.completed ||
                token.cpuHazardsRetired) {
                [_comparisons removeObjectForKey:key];
                comparison = nil;
            } else {
                BOOL readable = NO;
                if (![_surfaces tryIdleCPUReadSpans:sources
                                              count:indexed ? 2 : 1
                                          completed:&readable
                                              error:error])
                    return nil;
                const uint8_t *vram = _surfaces.vram.contents;
                if (readable &&
                    !memcmp(comparison.source.bytes, vram + c.address,
                            c.length) &&
                    (!indexed ||
                     !memcmp(comparison.palette.bytes, vram + c.palette_address,
                             c.palette_length))) {
                    previous = candidate;
                    content = candidate.content;
                    reusedContent = YES;
                }
            }
            [key setLookupWords:words];
        }
    }
    if (!content) {
        const NV2AMetalVRAMReadPattern reads[] = {
            { .address = c.address, .length = c.length },
            { .address = c.palette_address, .length = c.palette_length },
        };
        if (rtt) {
            if (packed1555 && surface.transfer.config.scale > 1) {
                /* Pure cold preparation precedes any capture/recording change.
                 */
                if (![surface.transfer prepareDownloadWithError:error])
                    return nil;
                content = [self captureDownsampledPacked1555:surface
                                                       frame:frame
                                                      format:c.shape.format
                                                       error:error];
            } else if (downsampleOpaque) {
                /* Like converted capture, pipeline failure must leave an
                 * unrelated open recording intact and never select RAM. */
                if (![self prepareDownsampleCaptureWithError:error])
                    return nil;
                content = [self captureDownsampledOpaque:surface
                                                   frame:frame
                                                  format:c.shape.format
                                                   error:error];
            } else if (swizzledChannels &&
                       (surface.transfer.config.scale > 1 ||
                        rtt_swizzled_channel_order(c.shape.format) == 3)) {
                if (![self prepareDownsampleChannelsCaptureWithError:error])
                    return nil;
                content = [self captureDownsampledChannels:surface
                                                     frame:frame
                                                    format:c.shape.format
                                                     error:error];
            } else {
                if (rtt_storage(surface, c.shape.format) ==
                        NV2AMetalTextureStorageFloat32 &&
                    ![self prepareCaptureWithError:error])
                    return nil;
                content = [self capture:surface
                                  frame:frame
                                 format:c.shape.format
                                  error:error];
            }
            content.rectangle = rtt_linear_format(c.shape.format);
        } else if ([_surfaces prepareTextureUploadReadPatterns:reads
                                                         count:indexed ? 2 : 1
                                                         error:error]) {
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
                uploaded = YES;
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
    } else if (recordGPUUse) {
        if (![_surfaces prepareCachedTextureBindingWithError:error])
            return nil;
    } else if (!*collectedFeedback) {
        if (![_surfaces collectCompletedWithError:error])
            return nil;
        *collectedFeedback = YES;
    }
    NV2AMetalSamplerConfig policy = *sampler;
    policy.signed_channels = c.shape.signed_channels;
    policy.hilo16 =
        c.shape.format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16 ||
        c.shape.format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16;
    policy.rectangle = content.rectangle;
    policy.bordered = c.shape.border;
    policy.min_level = rtt || content.rectangle ? content.minLevel :
                                                   c.shape.min_level;
    policy.max_level = rtt || content.rectangle ? content.maxLevel :
                                                   c.shape.max_level;
    NV2AMetalCachedTexture *result = previous;
    if (![previous matchesPolicy:&policy]) {
        NV2AMetalTextureBinding *binding =
            [_sampler bindingForTexture:content.texture
                                 config:&policy
                                  error:error];
        result = binding ?
            [[NV2AMetalCachedTexture alloc] initWithContent:content
                                                   binding:binding
                                                    policy:&policy] : nil;
    }
    if (!result ||
        (content.token.completed &&
         ![result validateCompletedWithError:error]) ||
        (recordGPUUse && ![_surfaces.commands addResource:result.binding.texture
                                                    error:error])) {
        [_surfaces cancel];
        [key setLookupWords:words];
        [_entries removeObjectForKey:key];
        return nil;
    }
    /* The lookup already promoted a hit. Replace its snapshot only after
     * a successful policy change so earlier draws keep their own bindings. */
    if (result != previous || reusedContent) {
        [key setLookupWords:words];
        _entries[key] = result;
    }
    if (compareSource && (uploaded || reusedContent)) {
        if (uploaded) {
            BOOL readable = NO;
            if (![_surfaces tryIdleCPUReadSpans:sources count:indexed ? 2 : 1
                                     completed:&readable error:error]) {
                [_surfaces cancel];
                [_entries removeObjectForKey:key];
                return nil;
            }
            comparison = nil;
            if (readable && !content.token.completed && !content.token.cancelled) {
                const uint8_t *vram = _surfaces.vram.contents;
                comparison = [NV2AMetalTextureComparison new];
                comparison.source = [NSData dataWithBytes:vram + c.address
                                                   length:c.length];
                if (indexed)
                    comparison.palette =
                        [NSData dataWithBytes:vram + c.palette_address
                                       length:c.palette_length];
            }
        }
        if (comparison) {
            comparison.texture = result;
            if (!_comparisons)
                _comparisons = [[NV2AMetalLRUCache alloc] initWithCapacity:64];
            [key setLookupWords:comparisonWords];
            _comparisons[key] = comparison;
        }
    }
    return result;
}
@end
