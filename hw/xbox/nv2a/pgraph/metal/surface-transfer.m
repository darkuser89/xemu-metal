/*
 * Native surface transfers from gl/surface.c
 * Copyright (c) 2012 espes
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2018-2025 Matt Borgerson
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#import "surface-transfer.h"
#import "shader-library.h"
#include "surface-transfer-types.h"
#include "surface-transfer-source.h"
#include <stdint.h>
#include <stdatomic.h>

_Static_assert(sizeof(NV2AMetalSurfaceTransferUniforms) == 52,
               "CPU/MSL surface transfer");

static BOOL surface_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.surface-transfer"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

static MTLPixelFormat surface_format(const NV2AMetalSurfaceConfig *c,
                                     unsigned int *bytes)
{
    *bytes = 0;
    if (!c) {
        return MTLPixelFormatInvalid;
    }
    if (!c->color) {
        if (c->format == NV097_SET_SURFACE_FORMAT_ZETA_Z24S8) {
            /* Fixed and floating Z24 surfaces store ordered guest depth codes.
             */
            *bytes = 4;
            return MTLPixelFormatDepth32Float_Stencil8;
        }
        if (c->format == NV097_SET_SURFACE_FORMAT_ZETA_Z16) {
            *bytes = 2;
            return c->floating_depth ? MTLPixelFormatDepth32Float :
                                       MTLPixelFormatDepth16Unorm;
        }
        return MTLPixelFormatInvalid;
    }
    switch (c->format) {
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5:
        *bytes = 2;
        return MTLPixelFormatBGR5A1Unorm;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5:
        *bytes = 2;
        return MTLPixelFormatB5G6R5Unorm;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8:
        *bytes = 4;
        return MTLPixelFormatBGRA8Unorm;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_B8:
        *bytes = 1;
        return MTLPixelFormatR8Unorm;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8:
        *bytes = 2;
        return MTLPixelFormatRG8Unorm;
    default:
        return MTLPixelFormatInvalid;
    }
}

static BOOL power_of_two(unsigned int x)
{
    return x && !(x & (x - 1));
}

static NSUInteger surface_span(unsigned int width, unsigned int height,
                               unsigned int pitch, unsigned int bytes,
                               BOOL swizzle)
{
    return swizzle ?
               (NSUInteger)width * height * bytes :
               (NSUInteger)(height - 1) * pitch + (NSUInteger)width * bytes;
}

BOOL nv2a_metal_surface_layout(const NV2AMetalSurfaceConfig *c,
                               NV2AMetalSurfaceLayout *layout, NSError **error)
{
    unsigned int bytes;
    MTLPixelFormat format = surface_format(c, &bytes);
    if (format == MTLPixelFormatInvalid || !c->width || !c->height ||
        !c->scale || c->width > 16384 / c->scale ||
        c->height > 16384 / c->scale || c->pitch < c->width * bytes ||
        c->pitch % bytes ||
        (c->swizzle && (!power_of_two(c->width) || !power_of_two(c->height)))) {
        return surface_error(error, @"Invalid native surface layout/format");
    }
    NSUInteger source =
        surface_span(c->width, c->height, c->pitch, bytes, c->swizzle);
    if (source > UINT32_MAX) {
        return surface_error(
            error, @"Surface transfer span exceeds native address range");
    }
    if (layout) {
        *layout = (NV2AMetalSurfaceLayout){ format, bytes, source,
                                            (NSUInteger)c->height * c->pitch };
    }
    return YES;
}

@interface NV2AMetalFreeSurfaceTexture : NSObject
@property(nonatomic) id<MTLTexture> texture;
@property(nonatomic) MTLTextureDescriptor *descriptor;
@property(nonatomic) NSUInteger bytes;
@end
@implementation NV2AMetalFreeSurfaceTexture
@end

/* Compare the complete final SurfaceTransfer descriptor rather than guest
 * config: different guest layouts may use identical native storage. This is
 * private to the descriptors constructed below, not a general texture pool. */
static BOOL surface_descriptors_equal(MTLTextureDescriptor *a,
                                      MTLTextureDescriptor *b)
{
    return a.textureType == b.textureType && a.pixelFormat == b.pixelFormat &&
           a.width == b.width && a.height == b.height && a.depth == b.depth &&
           a.mipmapLevelCount == b.mipmapLevelCount &&
           a.sampleCount == b.sampleCount && a.arrayLength == b.arrayLength &&
           a.resourceOptions == b.resourceOptions &&
           a.cpuCacheMode == b.cpuCacheMode && a.storageMode == b.storageMode &&
           a.hazardTrackingMode == b.hazardTrackingMode && a.usage == b.usage &&
           a.allowGPUOptimizedContents == b.allowGPUOptimizedContents &&
           a.compressionType == b.compressionType &&
           a.placementSparsePageSize == b.placementSparsePageSize &&
           a.swizzle.red == b.swizzle.red &&
           a.swizzle.green == b.swizzle.green &&
           a.swizzle.blue == b.swizzle.blue &&
           a.swizzle.alpha == b.swizzle.alpha;
}

@interface NV2AMetalSurfaceTexturePool ()
- (nullable id<MTLTexture>)takeTextureWithDescriptor:
    (MTLTextureDescriptor *)descriptor;
- (void)returnTexture:(id<MTLTexture>)texture
           descriptor:(MTLTextureDescriptor *)descriptor;
@end

@implementation NV2AMetalSurfaceTexturePool {
    NSMutableArray<NV2AMetalFreeSurfaceTexture *> *_freeTextures;
    NSUInteger _maximumBytes, _maximumCount, _freeBytes;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device
{
    return [self initWithDevice:device
                   maximumBytes:32u * 1024u * 1024u
                   maximumCount:8];
}
- (instancetype)initWithDevice:(id<MTLDevice>)device
                  maximumBytes:(NSUInteger)maximumBytes
                  maximumCount:(NSUInteger)maximumCount
{
    self = [super init];
    if (self) {
        _device = device;
        _maximumBytes = maximumBytes;
        _maximumCount = maximumCount;
        _freeTextures = [NSMutableArray new];
        if (!_freeTextures)
            return nil;
    }
    return self;
}
- (id<MTLTexture>)takeTextureWithDescriptor:(MTLTextureDescriptor *)descriptor
{
    if (!descriptor)
        return nil;
    @synchronized(self) {
        for (NSUInteger i = _freeTextures.count; i; i--) {
            NV2AMetalFreeSurfaceTexture *entry = _freeTextures[i - 1];
            if (entry.texture.device == _device &&
                surface_descriptors_equal(entry.descriptor, descriptor)) {
                id<MTLTexture> texture = entry.texture;
                _freeBytes -= entry.bytes;
                [_freeTextures removeObjectAtIndex:i - 1];
                return texture;
            }
        }
    }
    return nil;
}
- (void)returnTexture:(id<MTLTexture>)texture
           descriptor:(MTLTextureDescriptor *)descriptor
{
    NSUInteger bytes = texture.allocatedSize;
    if (!descriptor || texture.device != _device || !bytes || !_maximumCount ||
        bytes > _maximumBytes)
        return;
    NV2AMetalFreeSurfaceTexture *entry = [NV2AMetalFreeSurfaceTexture new];
    if (!entry)
        return;
    entry.texture = texture;
    entry.descriptor = [descriptor copy];
    if (!entry.descriptor)
        return;
    entry.bytes = bytes;
    @synchronized(self) {
        while (_freeTextures.count >= _maximumCount ||
               _freeBytes > _maximumBytes - bytes) {
            _freeBytes -= _freeTextures.firstObject.bytes;
            [_freeTextures removeObjectAtIndex:0];
        }
        [_freeTextures addObject:entry];
        _freeBytes += bytes;
    }
}
@end

@implementation NV2AMetalSurfaceTransfer {
    id<MTLDevice> _device;
    id<MTLTexture> _texture;
    __weak NV2AMetalSurfaceTexturePool *_texturePool;
    MTLTextureDescriptor *_textureDescriptor;
    atomic_bool _textureEscaped;
    NV2AMetalShaderLibrary *_sharedLibrary;
    id<MTLComputePipelineState> _upload, _download;
    id<MTL4ArgumentTable> _arguments;
    unsigned int _bytes, _stagingPitch, _stencilPitch, _stencilOffset;
    BOOL _packedZeta, _halfDepth, _directColorDownload;
    unsigned int _nativeBytes;
    NSUInteger _stagingLength;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                        config:(const NV2AMetalSurfaceConfig *)c
                         error:(NSError **)error
{
    return [self initWithDevice:device config:c texturePool:nil error:error];
}
- (instancetype)initWithDevice:(id<MTLDevice>)device
                        config:(const NV2AMetalSurfaceConfig *)c
                   texturePool:(NV2AMetalSurfaceTexturePool *)texturePool
                         error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }
    atomic_init(&_textureEscaped, false);
    NV2AMetalSurfaceLayout layout;
    if (!device.hasUnifiedMemory ||
        ![device supportsFamily:MTLGPUFamilyApple7] ||
        ![device supportsFamily:MTLGPUFamilyMetal4]) {
        surface_error(error, @"Native surfaces require Apple Silicon Metal 4");
        return nil;
    }
    if (!nv2a_metal_surface_layout(c, &layout, error)) {
        return nil;
    }
    if (texturePool && texturePool.device != device) {
        surface_error(error,
                      @"Surface texture pool belongs to a different GPU");
        return nil;
    }
    MTLPixelFormat format = layout.pixel_format;
    _bytes = layout.bytes_per_pixel;
    _directColorDownload = format == MTLPixelFormatR8Unorm ||
                           format == MTLPixelFormatRG8Unorm ||
                           format == MTLPixelFormatBGRA8Unorm;
    _sourceLength = layout.source_length;
    _device = device;
    _config = *c;
    unsigned int width = c->width * c->scale, height = c->height * c->scale;
    _halfDepth = format == MTLPixelFormatDepth32Float;
    _nativeBytes = _halfDepth ? 4 : _bytes;
    _stagingPitch = (width * _nativeBytes + 255) & ~255u;
    _stagingLength = (NSUInteger)_stagingPitch * height;
    _packedZeta = format == MTLPixelFormatDepth32Float_Stencil8;
    if (_packedZeta) {
        _stencilPitch = (width + 255) & ~255u;
        _stencilOffset = (unsigned int)_stagingLength;
        _stagingLength += (NSUInteger)_stencilPitch * height;
    }
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
               MTLTextureUsagePixelFormatView;
    _texturePool = texturePool;
    _textureDescriptor = texturePool ? [td copy] : nil;
    _texture = [texturePool takeTextureWithDescriptor:td];
    if (!_texture)
        _texture = [device newTextureWithDescriptor:td];
    if (!_texture) {
        surface_error(error, @"Cannot allocate native surface texture");
        return nil;
    }
    return self;
}

- (id<MTLTexture>)texture
{
    atomic_store_explicit(&_textureEscaped, true, memory_order_release);
    return _texture;
}
- (MTLPixelFormat)nativePixelFormat
{
    return _texture.pixelFormat;
}
- (NSUInteger)nativeWidth
{
    return _texture.width;
}
- (NSUInteger)nativeHeight
{
    return _texture.height;
}
- (MTLTextureSwizzleChannels)nativeSwizzle
{
    return _texture.swizzle;
}
- (id<MTLTexture>)textureForCommands:(NV2AMetalCommands *)commands
                               error:(NSError **)error
{
    if (!commands.commandBuffer || commands.device != _device) {
        surface_error(error, @"Invalid surface texture borrow context/device");
        return nil;
    }
    return [commands keepAlive:self error:error] ? _texture : nil;
}
- (void)dealloc
{
    NV2AMetalSurfaceTexturePool *pool = _texturePool;
    if (_texture && pool &&
        !atomic_load_explicit(&_textureEscaped, memory_order_acquire))
        [pool returnTexture:_texture descriptor:_textureDescriptor];
}

- (BOOL)prepareComputeForUpload:(BOOL)upload error:(NSError **)error
{
    if (!_sharedLibrary) {
        _sharedLibrary =
            [NV2AMetalShaderLibrary sharedWithDevice:_device
                                              source:metal_shader_source
                                               error:error];
        if (!_sharedLibrary)
            return NO;
    }
    id<MTLComputePipelineState> pipeline = upload ? _upload : _download;
    if (!pipeline) {
        NSString *name = upload               ? @"nv2a_surface_upload" :
                         _directColorDownload ? @"nv2a_surface_download_color" :
                                                @"nv2a_surface_download";
        pipeline = [_sharedLibrary computeFunction:name error:error];
        if (!pipeline)
            return NO;
        if (upload)
            _upload = pipeline;
        else
            _download = pipeline;
    }
    if (!_arguments) {
        MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
        ad.maxBufferBindCount = 3;
        ad.maxTextureBindCount = 1;
        ad.initializeBindings = YES;
        _arguments = [_device newArgumentTableWithDescriptor:ad error:error];
        if (!_arguments)
            return NO;
    }
    return YES;
}

- (BOOL)prepareDownloadWithError:(NSError **)error
{
    return [self prepareComputeForUpload:NO error:error];
}

- (BOOL)canCopyBufferAtOffset:(NSUInteger)offset
                     uniforms:(NV2AMetalSurfaceTransferUniforms)u
                       upload:(BOOL)upload
{
    unsigned pitch = upload ? u.source_pitch : u.destination_pitch;
    BOOL nativeFixedZ16 = !_config.color &&
                          _config.format == NV097_SET_SURFACE_FORMAT_ZETA_Z16 &&
                          !_config.floating_depth &&
                          _texture.pixelFormat == MTLPixelFormatDepth16Unorm;
    return (_config.color || nativeFixedZ16) && !u.swizzle && !u.flip &&
           u.scale == 1 && u.width == _texture.width &&
           u.height == _texture.height && !(offset % _bytes) &&
           pitch <= 16384u * _bytes;
}

- (BOOL)encodeBuffer:(id<MTLBuffer>)buffer
              offset:(NSUInteger)offset
            uniforms:(NV2AMetalSurfaceTransferUniforms)u
              upload:(BOOL)upload
            commands:(NV2AMetalCommands *)commands
               error:(NSError **)error
{
    NSUInteger span = upload ?
                          _sourceLength :
                          surface_span(u.width, u.height, u.destination_pitch,
                                       _bytes, u.swizzle);
    if (!commands.commandBuffer || commands.device != _device ||
        buffer.device != _device || span > UINT32_MAX ||
        offset > buffer.length || span > buffer.length - offset) {
        return surface_error(error,
                             @"Invalid surface transfer buffer span/context");
    }
    if ([self canCopyBufferAtOffset:offset uniforms:u upload:upload]) {
        if (![commands addResource:buffer error:error] ||
            ![commands addResource:_texture error:error] ||
            ![commands keepAlive:self error:error])
            return NO;
        id<MTL4ComputeCommandEncoder> e =
            [commands.commandBuffer computeCommandEncoder];
        if (!e)
            return surface_error(error, @"Cannot create surface copy encoder");
        [e barrierAfterQueueStages:MTLStageAll
                      beforeStages:MTLStageBlit
                 visibilityOptions:MTL4VisibilityOptionDevice];
        MTLSize size = MTLSizeMake(u.width, u.height, 1);
        if (upload) {
            [e copyFromBuffer:buffer
                       sourceOffset:offset
                  sourceBytesPerRow:u.source_pitch
                sourceBytesPerImage:0
                         sourceSize:size
                          toTexture:_texture
                   destinationSlice:0
                   destinationLevel:0
                  destinationOrigin:MTLOriginMake(0, 0, 0)];
        } else {
            [e copyFromTexture:_texture
                             sourceSlice:0
                             sourceLevel:0
                            sourceOrigin:MTLOriginMake(0, 0, 0)
                              sourceSize:size
                                toBuffer:buffer
                       destinationOffset:offset
                  destinationBytesPerRow:u.destination_pitch
                destinationBytesPerImage:0
                                 options:MTLBlitOptionNone];
        }
        [e barrierAfterStages:MTLStageBlit
            beforeQueueStages:MTLStageAll
            visibilityOptions:MTL4VisibilityOptionDevice];
        [e endEncoding];
        return YES;
    }
    if (![self prepareComputeForUpload:upload error:error])
        return NO;
    BOOL direct = !upload && _directColorDownload;
    id<MTLBuffer> staging =
        direct ? nil :
                 [commands orderedTransferScratchWithLength:_stagingLength
                                                      error:error];
    if (!direct && !staging)
        return NO;
    NSUInteger uniformOffset = 0;
    id<MTLBuffer> constants = [commands uploadBytes:&u
                                             length:sizeof(u)
                                             offset:&uniformOffset
                                              error:error];
    if (!constants)
        return NO;
    if (![commands addResource:buffer error:error] ||
        ![commands addResource:_texture error:error] ||
        ![commands keepAlive:self error:error]) {
        return NO;
    }
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    if (!e) {
        return surface_error(error, @"Cannot create surface transfer encoder");
    }
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [_arguments setAddress:upload ? buffer.gpuAddress + offset :
                           direct ? constants.gpuAddress + uniformOffset :
                                    staging.gpuAddress
                   atIndex:0];
    [_arguments
        setAddress:upload ? staging.gpuAddress : buffer.gpuAddress + offset
           atIndex:1];
    [_arguments setAddress:constants.gpuAddress + uniformOffset atIndex:2];
    if (direct)
        [_arguments setTexture:_texture.gpuResourceID atIndex:0];
    if (!upload && !direct) {
        [e copyFromTexture:_texture
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(_texture.width,
                                                 _texture.height, 1)
                            toBuffer:staging
                   destinationOffset:0
              destinationBytesPerRow:_stagingPitch
            destinationBytesPerImage:0
                             options:_packedZeta ?
                                         MTLBlitOptionDepthFromDepthStencil :
                                         MTLBlitOptionNone];
        if (_packedZeta) {
            [e copyFromTexture:_texture
                             sourceSlice:0
                             sourceLevel:0
                            sourceOrigin:MTLOriginMake(0, 0, 0)
                              sourceSize:MTLSizeMake(_texture.width,
                                                     _texture.height, 1)
                                toBuffer:staging
                       destinationOffset:_stencilOffset
                  destinationBytesPerRow:_stencilPitch
                destinationBytesPerImage:0
                                 options:MTLBlitOptionStencilFromDepthStencil];
        }
        [e barrierAfterEncoderStages:MTLStageBlit
                 beforeEncoderStages:MTLStageDispatch
                   visibilityOptions:MTL4VisibilityOptionDevice];
    }
    [e setComputePipelineState:upload ? _upload : _download];
    [e setArgumentTable:_arguments];
    [e dispatchThreads:MTLSizeMake(u.width, u.height, 1)
        threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    if (upload) {
        [e barrierAfterEncoderStages:MTLStageDispatch
                 beforeEncoderStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
        [e copyFromBuffer:staging
                   sourceOffset:0
              sourceBytesPerRow:_stagingPitch
            sourceBytesPerImage:0
                     sourceSize:MTLSizeMake(_texture.width, _texture.height, 1)
                      toTexture:_texture
               destinationSlice:0
               destinationLevel:0
              destinationOrigin:MTLOriginMake(0, 0, 0)
                        options:_packedZeta ?
                                    MTLBlitOptionDepthFromDepthStencil :
                                    MTLBlitOptionNone];
        if (_packedZeta) {
            [e copyFromBuffer:staging
                       sourceOffset:_stencilOffset
                  sourceBytesPerRow:_stencilPitch
                sourceBytesPerImage:0
                         sourceSize:MTLSizeMake(_texture.width, _texture.height,
                                                1)
                          toTexture:_texture
                   destinationSlice:0
                   destinationLevel:0
                  destinationOrigin:MTLOriginMake(0, 0, 0)
                            options:MTLBlitOptionStencilFromDepthStencil];
        }
    }
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return YES;
}

- (BOOL)encodeUploadFromBuffer:(id<MTLBuffer>)source
                        offset:(NSUInteger)offset
                      commands:(NV2AMetalCommands *)commands
                         error:(NSError **)error
{
    NV2AMetalSurfaceTransferUniforms u = {
        .width = (unsigned int)_texture.width,
        .height = (unsigned int)_texture.height,
        .bytes_per_pixel = _bytes,
        .source_pitch = _config.pitch,
        .destination_pitch = _stagingPitch,
        .scale = _config.scale,
        .swizzle = _config.swizzle,
        .packed_zeta = _packedZeta,
        .stencil_pitch = _stencilPitch,
        .stencil_offset = _stencilOffset,
        .native_bytes_per_pixel = _nativeBytes,
        .half_depth = _halfDepth,
    };
    return [self encodeBuffer:source
                       offset:offset
                     uniforms:u
                       upload:YES
                     commands:commands
                        error:error];
}

- (BOOL)encodeDownloadToBuffer:(id<MTLBuffer>)destination
                        offset:(NSUInteger)offset
                       swizzle:(BOOL)swizzle
                          flip:(BOOL)flip
                     downscale:(BOOL)downscale
                      commands:(NV2AMetalCommands *)commands
                         error:(NSError **)error
{
    swizzle &= _config.swizzle;
    if ((swizzle && !downscale && _config.scale != 1) ||
        (!downscale && _config.pitch > UINT32_MAX / _config.scale)) {
        return surface_error(error, @"Invalid scaled surface download layout");
    }
    NV2AMetalSurfaceTransferUniforms u = {
        .width = downscale ? _config.width : (unsigned int)_texture.width,
        .height = downscale ? _config.height : (unsigned int)_texture.height,
        .bytes_per_pixel = _bytes,
        .source_pitch = _stagingPitch,
        .destination_pitch =
            downscale ? _config.pitch : _config.pitch * _config.scale,
        .scale = downscale ? _config.scale : 1,
        .swizzle = swizzle,
        .flip = flip,
        .packed_zeta = _packedZeta,
        .stencil_pitch = _stencilPitch,
        .stencil_offset = _stencilOffset,
        .native_bytes_per_pixel = _nativeBytes,
        .half_depth = _halfDepth,
    };
    return [self encodeBuffer:destination
                       offset:offset
                     uniforms:u
                       upload:NO
                     commands:commands
                        error:error];
}
@end
