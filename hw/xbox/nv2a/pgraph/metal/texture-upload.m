/* SPDX-License-Identifier: LGPL-2.0-or-later */

#import "texture-upload.h"
#import "shader-library.h"
#include "texture-upload-types.h"
#include "texture-storage.h"
#include "texture-upload-source.h"
#include <stdint.h>

_Static_assert(sizeof(NV2AMetalTextureDecodeUniforms) == 68,
               "CPU/MSL texture decode");

typedef struct TextureFormat {
    unsigned int bytes, block;
    BOOL linear, depth, snorm;
} TextureFormat;

static TextureFormat texture_format(unsigned int format)
{
    switch (format) {
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8:
        return (TextureFormat){ 1, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_AY8:
        return (TextureFormat){ 1, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A1R5G5B5:
        return (TextureFormat){ 2, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5:
        return (TextureFormat){ 2, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A4R4G4B4:
        return (TextureFormat){ 2, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R5G6B5:
        return (TextureFormat){ 2, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8:
        return (TextureFormat){ 4, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8:
        return (TextureFormat){ 4, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8:
        return (TextureFormat){ 1, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT1_A1R5G5B5:
        return (TextureFormat){ 4, 8, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT23_A8R8G8B8:
        return (TextureFormat){ 4, 16, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT45_A8R8G8B8:
        return (TextureFormat){ 4, 16, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5:
        return (TextureFormat){ 2, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5:
        return (TextureFormat){ 2, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8:
        return (TextureFormat){ 4, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8:
        return (TextureFormat){ 1, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_G8B8:
        return (TextureFormat){ 2, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8:
        return (TextureFormat){ 1, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8Y8:
        return (TextureFormat){ 2, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_AY8:
        return (TextureFormat){ 1, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5:
        return (TextureFormat){ 2, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A4R4G4B4:
        return (TextureFormat){ 2, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8:
        return (TextureFormat){ 4, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8:
        return (TextureFormat){ 1, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8Y8:
        return (TextureFormat){ 2, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R6G5B5:
        return (TextureFormat){ 2, 0, false, false, true };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_G8B8:
        return (TextureFormat){ 2, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8B8:
        return (TextureFormat){ 2, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LC_IMAGE_CR8YB8CB8YA8:
        return (TextureFormat){ 2, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LC_IMAGE_YB8CR8YA8CB8:
        return (TextureFormat){ 2, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_DEPTH_Y16_FIXED:
        return (TextureFormat){ 2, 0, false, true, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_X8_Y24_FIXED:
        return (TextureFormat){ 4, 0, true, true, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_X8_Y24_FLOAT:
        return (TextureFormat){ 4, 0, true, true, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_Y16_FIXED:
        return (TextureFormat){ 2, 0, true, true, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_Y16_FLOAT:
        return (TextureFormat){ 2, 0, true, true, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y16:
        return (TextureFormat){ 2, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y16:
        return (TextureFormat){ 2, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16:
        return (TextureFormat){ 4, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16:
        return (TextureFormat){ 4, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8:
        return (TextureFormat){ 4, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8:
        return (TextureFormat){ 4, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8:
        return (TextureFormat){ 4, 0, false, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8:
        return (TextureFormat){ 4, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8:
        return (TextureFormat){ 4, 0, true, false, false };
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8:
        return (TextureFormat){ 4, 0, true, false, false };
    default:
        return (TextureFormat){ 0 };
    }
}

static BOOL upload_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.texture-upload"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

/* These decoders produce integer byte channels divided by 255. Packed 4/5/6
 * bit, HILO and depth decoders retain their original float precision. */
static BOOL compact_unorm8(const NV2AMetalTextureShape *shape)
{
    if (shape->signed_channels) {
        return NO;
    }
    switch (shape->format) {
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT1_A1R5G5B5:
    case NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT23_A8R8G8B8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT45_A8R8G8B8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LC_IMAGE_CR8YB8CB8YA8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LC_IMAGE_YB8CR8YA8CB8:
        return YES;
    default:
        return NO;
    }
}

static unsigned texture_storage(const NV2AMetalTextureShape *shape)
{
    switch (shape->format) {
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8:
        return NV2AMetalTextureStorageByteY8;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_AY8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_AY8:
        return NV2AMetalTextureStorageByteAY8;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8:
        return NV2AMetalTextureStorageByteA8;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8Y8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8Y8:
        return NV2AMetalTextureStorageByteA8Y8;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_G8B8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_G8B8:
        return NV2AMetalTextureStorageByteG8B8;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8B8:
        return NV2AMetalTextureStorageByteR8B8;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R6G5B5:
        return NV2AMetalTextureStorageSnorm8;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A1R5G5B5:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5:
        return NV2AMetalTextureStoragePackedA1555;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5:
        return NV2AMetalTextureStoragePackedX1555;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A4R4G4B4:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A4R4G4B4:
        return NV2AMetalTextureStoragePackedA4444;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R5G6B5:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5:
        return NV2AMetalTextureStoragePackedR565;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y16:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y16:
        return NV2AMetalTextureStorageFloatY16;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16:
        return NV2AMetalTextureStorageFloatHILO16;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_DEPTH_Y16_FIXED:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_Y16_FIXED:
        return NV2AMetalTextureStorageFloatDepthY16;
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_X8_Y24_FIXED:
        return NV2AMetalTextureStorageFloatDepth24Fixed;
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_X8_Y24_FLOAT:
        return NV2AMetalTextureStorageFloatDepth24Float;
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_DEPTH_Y16_FLOAT:
        return NV2AMetalTextureStorageFloatDepth16Float;
    default:
        return shape->signed_channels ? NV2AMetalTextureStorageHalf4 :
               compact_unorm8(shape)  ? NV2AMetalTextureStorageUnorm8 :
                                        NV2AMetalTextureStorageFloat32;
    }
}

static BOOL power_of_two(unsigned int value)
{
    return value && !(value & (value - 1));
}

static unsigned int max_uint(unsigned int a, unsigned int b)
{
    return a > b ? a : b;
}

typedef struct TextureLevel {
    NV2AMetalTextureDecodeUniforms uniforms;
    NSUInteger offset, length, output_length;
} TextureLevel;

typedef struct TextureLayout {
    TextureLevel layout[15];
    TextureFormat format;
    unsigned int levels, depth;
    BOOL indexed;
    NSUInteger face_stride, source_length;
} TextureLayout;

static BOOL same_texture_shape(const NV2AMetalTextureShape *a,
                               const NV2AMetalTextureShape *b)
{
    return a->format == b->format && a->dimension == b->dimension &&
           a->width == b->width && a->height == b->height &&
           a->depth == b->depth && a->levels == b->levels &&
           a->pitch == b->pitch && a->cubemap == b->cubemap &&
           a->border == b->border && a->signed_channels == b->signed_channels;
}

static BOOL texture_layout(const NV2AMetalTextureShape *shape,
                           NSUInteger paletteLength, NSUInteger maxBufferLength,
                           unsigned storage, TextureLayout *output,
                           NSError **error)
{
    memset(output, 0, sizeof(*output));
    TextureFormat f = texture_format(shape ? shape->format : UINT32_MAX);
    if (!shape || !f.bytes ||
        (shape->dimension != 2 && shape->dimension != 3) || !shape->width ||
        !shape->height || shape->width > 16384 || shape->height > 16384 ||
        (f.linear && (shape->dimension != 2 || shape->cubemap)) ||
        (!f.linear &&
         (!power_of_two(shape->width) || !power_of_two(shape->height))) ||
        (shape->dimension == 3 &&
         (shape->cubemap || !power_of_two(shape->depth) ||
          shape->width > 2048 || shape->height > 2048 ||
          shape->depth > 2048)) ||
        (shape->cubemap && shape->width != shape->height)) {
        upload_error(error, @"Invalid Metal texture shape or command context");
        return NO;
    }
    BOOL signedHILO16 =
        shape->signed_channels == 15 &&
        (shape->format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_YB_16_YA_16 ||
         shape->format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_YB16YA16);
    if (shape->signed_channels > 15 ||
        (shape->signed_channels && !signedHILO16 &&
         shape->format != NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8 &&
         shape->format != NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8 &&
         shape->format != NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8 &&
         shape->format != NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8 &&
         shape->format != NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8 &&
         shape->format != NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8 &&
         shape->format != NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8 &&
         shape->format != NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8)) {
        upload_error(error, @"Unsupported signed-channel texture format");
        return NO;
    }
    unsigned int levels = f.linear ? 1 : shape->levels;
    if (!levels || levels > 15 ||
        (!f.linear &&
         (shape->min_level > shape->max_level || shape->max_level >= levels))) {
        upload_error(error, @"Invalid Metal texture mip levels");
        return NO;
    }
    BOOL indexed =
        shape->format == NV097_SET_TEXTURE_FORMAT_COLOR_SZ_I8_A8R8G8B8;
    if (indexed && paletteLength != 128 && paletteLength != 256 &&
        paletteLength != 512 && paletteLength != 1024) {
        upload_error(error, @"Invalid Metal texture palette length");
        return NO;
    }
    unsigned int w = shape->width, h = shape->height;
    unsigned int d = shape->dimension == 3 ? shape->depth : 1;
    if (!f.linear && shape->border) {
        w = max_uint(16u, w * 2);
        h = max_uint(16u, h * 2);
        if (shape->dimension == 3) {
            d = max_uint(16u, d * 2);
        }
    }
    if (w > (shape->dimension == 3 ? 2048u : 16384u) ||
        h > (shape->dimension == 3 ? 2048u : 16384u) || d > 2048) {
        upload_error(error, @"Border texture exceeds Metal dimensions");
        return NO;
    }
    TextureLevel *layout = output->layout;
    unsigned int output_bytes = nv2a_metal_texture_storage_bytes(storage);
    NSUInteger face_length = 0;
    unsigned int sw = w, sh = h, sd = d;
    for (unsigned int level = 0; level < levels; level++) {
        if (level && sw == 1 && sh == 1 && sd == 1) {
            /* The last 1x1 level is valid, but a duplicate beyond it is not. */
            unsigned int maximum = max_uint(w, max_uint(h, d));
            if ((maximum >> level) == 0) {
                upload_error(error,
                             @"Mip chain exceeds the texture dimensions");
                return NO;
            }
        }
        TextureLevel *l = &layout[level];
        NV2AMetalTextureDecodeUniforms *u = &l->uniforms;
        u->format = shape->format;
        u->signed_channels = shape->signed_channels;
        u->output_storage = storage;
        u->linear = f.linear;
        u->bytes_per_pixel = f.bytes;
        u->block_size = f.block;
        u->source_width = sw;
        u->source_height = sh;
        u->source_depth = sd;
        // Preserve physical cube borders at every mip. Face UVs are remapped
        // by the sampler instead of discarding the guest's gutter texels.
        u->width = sw;
        u->height = sh;
        u->depth = sd;
        u->palette_entries = indexed ? (unsigned int)(paletteLength / 4) : 0;
        if (f.linear) {
            NSUInteger row_min = (NSUInteger)sw * f.bytes;
            if (shape->format ==
                    NV097_SET_TEXTURE_FORMAT_COLOR_LC_IMAGE_CR8YB8CB8YA8 ||
                shape->format ==
                    NV097_SET_TEXTURE_FORMAT_COLOR_LC_IMAGE_YB8CR8YA8CB8) {
                row_min = ((NSUInteger)sw + 1) / 2 * 4;
            }
            if (shape->pitch < row_min || shape->pitch % f.bytes) {
                upload_error(error, @"Invalid Metal linear texture pitch");
                return NO;
            }
            u->source_pitch = shape->pitch;
            l->length = (NSUInteger)shape->pitch * sh;
        } else if (f.block) {
            l->length =
                (NSUInteger)((sw + 3) / 4) * ((sh + 3) / 4) * sd * f.block;
        } else {
            l->length = (NSUInteger)sw * sh * sd * f.bytes;
        }
        NSUInteger row = ((NSUInteger)u->width * output_bytes + 255) &
                         ~(NSUInteger)255;
        NSUInteger slice = row * u->height;
        l->output_length = slice * u->depth;
        if (l->length > UINT32_MAX || face_length > UINT32_MAX - l->length ||
            l->output_length > maxBufferLength ||
            l->output_length / output_bytes > UINT32_MAX) {
            upload_error(error, @"Metal texture decode span exceeds limits");
            return NO;
        }
        u->output_row = (unsigned int)(row / output_bytes);
        u->output_slice = (unsigned int)(slice / output_bytes);
        l->offset = face_length;
        face_length += l->length;
        sw = max_uint(sw / 2, 1u);
        sh = max_uint(sh / 2, 1u);
        sd = max_uint(sd / 2, 1u);
    }
    NSUInteger face_stride =
        shape->cubemap ? (face_length + NV2A_CUBEMAP_FACE_ALIGNMENT - 1) &
                             ~(NSUInteger)(NV2A_CUBEMAP_FACE_ALIGNMENT - 1) :
                         face_length;
    NSUInteger source_length = face_stride * (shape->cubemap ? 6 : 1);
    output->format = f;
    output->levels = levels;
    output->depth = d;
    output->indexed = indexed;
    output->face_stride = face_stride;
    output->source_length = source_length;
    return YES;
}

@implementation NV2AMetalTextureUploadResult
- (instancetype)initWithTexture:(id<MTLTexture>)texture
                         faults:(id<MTLBuffer>)faults
                   sourceLength:(NSUInteger)sourceLength
                          shape:(const NV2AMetalTextureShape *)shape
                         format:(TextureFormat)format
{
    self = [super init];
    if (self) {
        _texture = texture;
        _faults = faults;
        _sourceLength = sourceLength;
        _minLevel = format.linear ? 0 : shape->min_level;
        _maxLevel = format.linear ? 0 : shape->max_level;
        _rectangle = format.linear;
        _signedNormalized = format.snorm;
        _mixedSignedHalf = texture.pixelFormat == MTLPixelFormatRGBA16Float &&
                           shape->signed_channels &&
                           shape->signed_channels != 15;
        _depth = format.depth;
    }
    return self;
}
@end

@implementation NV2AMetalTextureUpload {
    id<MTLDevice> _device;
    NV2AMetalShaderLibrary *_module;
    id<MTLComputePipelineState> _pipeline;
    id<MTL4ArgumentTable> _arguments;
    id<MTLComputePipelineState> _blockPipeline;
    id<MTL4ArgumentTable> _blockArguments;
    id<MTLBuffer> _zeroFaults;
    NV2AMetalTextureShape _layoutShape;
    NSUInteger _layoutPaletteLength;
    TextureLayout _layout;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }
    if (![device supportsFamily:MTLGPUFamilyApple7] ||
        ![device supportsFamily:MTLGPUFamilyMetal4] ||
        !device.hasUnifiedMemory) {
        upload_error(error, @"Metal 4 texture upload requires Apple Silicon");
        return nil;
    }
    _device = device;
    return self;
}

- (BOOL)prepareDecoderWithError:(NSError **)error
{
    if (_arguments)
        return YES;
    if (!_module)
        _module = [NV2AMetalShaderLibrary sharedWithDevice:_device
                                                   source:metal_shader_source
                                                    error:error];
    if (!_module)
        return NO;
    if (!_pipeline)
        _pipeline = [_module computeFunction:@"nv2a_texture_decode" error:error];
    if (!_pipeline)
        return NO;
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 5;
    ad.initializeBindings = YES;
    _arguments = [_device newArgumentTableWithDescriptor:ad error:error];
    return _arguments != nil;
}

- (BOOL)canDecodeBCBlocksForShape:(const NV2AMetalTextureShape *)shape
{
    if (!shape || shape->signed_channels || !_layout.levels ||
        (shape->format != NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT1_A1R5G5B5 &&
         shape->format != NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT23_A8R8G8B8 &&
         shape->format != NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT45_A8R8G8B8))
        return NO;
    for (unsigned level = 0; level < _layout.levels; level++) {
        const NV2AMetalTextureDecodeUniforms *u =
            &_layout.layout[level].uniforms;
        if (u->format != shape->format || u->signed_channels ||
            u->output_storage != NV2AMetalTextureStorageUnorm8 || u->crop ||
            u->block_size != _layout.format.block ||
            u->width != u->source_width || u->height != u->source_height ||
            u->depth != u->source_depth)
            return NO;
    }
    return YES;
}

- (BOOL)prepareBlockDecoderWithError:(NSError **)error
{
    if (_blockArguments)
        return YES;
    if (!_module)
        _module = [NV2AMetalShaderLibrary sharedWithDevice:_device
                                                    source:metal_shader_source
                                                     error:error];
    if (!_module)
        return NO;
    if (!_blockPipeline)
        _blockPipeline =
            [_module computeFunction:@"nv2a_texture_decode_bc_blocks"
                               error:error];
    if (!_blockPipeline)
        return NO;
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 5;
    ad.initializeBindings = YES;
    _blockArguments = [_device newArgumentTableWithDescriptor:ad error:error];
    return _blockArguments != nil;
}
- (unsigned)storageForShape:(const NV2AMetalTextureShape *)shape
{
    if (!shape)
        return NV2AMetalTextureStorageFloat32;
    if (!shape->signed_channels) {
        if (shape->format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8)
            return NV2AMetalTextureStorageBGRA8;
        if (shape->format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8)
            return NV2AMetalTextureStorageBGRX8;
        if (shape->format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8)
            return NV2AMetalTextureStorageBGRA8GRAB;
        if (shape->format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8)
            return NV2AMetalTextureStorageBGRA8ARGB;
    }
    return texture_storage(shape);
}

- (BOOL)prepareLayoutForShape:(const NV2AMetalTextureShape *)shape
                paletteLength:(NSUInteger)paletteLength
                        error:(NSError **)error
{
    /* The DMA length query, cache validation and encoder normally visit
     * the same shape consecutively. Keep the validated CPU layout local to
     * this uploader. A failed layout leaves source_length zero. */
    if (_layout.source_length && shape &&
        _layoutPaletteLength == paletteLength &&
        same_texture_shape(&_layoutShape, shape) &&
        (_layout.format.linear ||
         (shape->min_level <= shape->max_level &&
          shape->max_level < _layout.levels))) {
        return YES;
    }
    if (!texture_layout(shape, paletteLength, _device.maxBufferLength,
                        [self storageForShape:shape], &_layout, error)) {
        return NO;
    }
    _layoutShape = *shape;
    _layoutPaletteLength = paletteLength;
    return YES;
}

- (BOOL)sourceLengthForShape:(const NV2AMetalTextureShape *)shape
               paletteLength:(NSUInteger)paletteLength
                      length:(NSUInteger *)length
                       error:(NSError **)error
{
    if (!length) {
        return upload_error(error, @"Missing texture layout length storage");
    }
    if (![self prepareLayoutForShape:shape paletteLength:paletteLength
                               error:error]) {
        return NO;
    }
    *length = _layout.source_length;
    return YES;
}

- (nullable NV2AMetalTextureUploadResult *)
       encodeData:(id<MTLBuffer>)data
           offset:(NSUInteger)offset
          palette:(nullable id<MTLBuffer>)palette
    paletteOffset:(NSUInteger)paletteOffset
    paletteLength:(NSUInteger)paletteLength
            shape:(const NV2AMetalTextureShape *)shape
         commands:(NV2AMetalCommands *)commands
            error:(NSError **)error
{
    if (commands.device != _device || !commands.commandBuffer ||
        data.device != _device || offset > data.length ||
        ![self prepareLayoutForShape:shape paletteLength:paletteLength
                               error:error]) {
        upload_error(error, @"Invalid Metal texture shape or command context");
        return nil;
    }
    TextureFormat f = _layout.format;
    unsigned int levels = _layout.levels, d = _layout.depth;
    BOOL indexed = _layout.indexed;
    const TextureLevel *layout = _layout.layout;
    NSUInteger face_stride = _layout.face_stride;
    NSUInteger source_length = _layout.source_length;
    if (indexed &&
        (palette.device != _device || paletteOffset > palette.length ||
         paletteLength > palette.length - paletteOffset)) {
        upload_error(error, @"Invalid Metal texture palette span");
        return nil;
    }
    if (source_length > data.length - offset) {
        upload_error(error,
                     @"Metal texture input does not contain all mip faces");
        return nil;
    }
    unsigned storage = layout[0].uniforms.output_storage;
    /* These linear formats match the backing texture byte order. Metal 4
     * copies require pixel-aligned offsets/pitches and a supported row width.
     */
    BOOL direct =
        ((f.linear && storage >= NV2AMetalTextureStorageByteY8 &&
          storage <= NV2AMetalTextureStorageByteR8B8) ||
         (shape->format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8 &&
          storage == NV2AMetalTextureStorageBGRA8) ||
         (shape->format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8 &&
          storage == NV2AMetalTextureStorageBGRX8) ||
         shape->format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8 ||
         (shape->format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8 &&
          storage == NV2AMetalTextureStorageBGRA8GRAB) ||
         (shape->format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8 &&
          storage == NV2AMetalTextureStorageBGRA8ARGB) ||
         shape->format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5 ||
         shape->format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5 ||
         shape->format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5 ||
         shape->format == NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A4R4G4B4) &&
        !shape->signed_channels && !(offset % f.bytes) &&
        shape->pitch <= 16384u * f.bytes;
    BOOL blocks = !direct && [self canDecodeBCBlocksForShape:shape];
    if (!direct && !(blocks ? [self prepareBlockDecoderWithError:error] :
                              [self prepareDecoderWithError:error]))
        return nil;
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = shape->cubemap        ? MTLTextureTypeCube :
                     shape->dimension == 3 ? MTLTextureType3D :
                                             MTLTextureType2D;
    unsigned int output_bytes = nv2a_metal_texture_storage_bytes(storage);
    td.pixelFormat = nv2a_metal_texture_storage_format(storage);
    td.swizzle = nv2a_metal_texture_storage_swizzle(storage);
    td.width = layout[0].uniforms.width;
    td.height = layout[0].uniforms.height;
    td.depth = d;
    td.mipmapLevelCount = levels;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> texture = [_device newTextureWithDescriptor:td];
    /* Only short palettes can write the fault word. Every other upload can
     * share the same zero result, even when its GPU work is still queued. */
    BOOL canFault = indexed && paletteLength < 256 * sizeof(uint32_t);
    id<MTLBuffer> faults = canFault ? nil : _zeroFaults;
    if (!faults && texture) {
        uint32_t zero = 0;
        faults = [_device newBufferWithBytes:&zero
                                     length:sizeof(zero)
                                    options:MTLResourceStorageModeShared];
        if (!canFault)
            _zeroFaults = faults;
    }
    if (!texture || !faults) {
        upload_error(error, @"Could not allocate Metal decoded texture");
        return nil;
    }
    if (![commands addResource:data error:error] ||
        (indexed && ![commands addResource:palette error:error]) ||
        ![commands addResource:texture error:error] ||
        (!direct && ![commands addResource:faults error:error]) ||
        ![commands keepAlive:self error:error]) {
        return nil;
    }
    /* Mip dimensions and aligned output spans are nonincreasing. Each
     * dispatch's blit finishes reading before the next mip or face writes. */
    id<MTLBuffer> scratch = nil;
    MTLGPUAddress uniforms[sizeof(_layout.layout) / sizeof(*layout)];
    if (!direct) {
        scratch = [commands orderedTransferScratchWithLength:layout[0].output_length
                                                       error:error];
        if (!scratch)
            return nil;
        for (unsigned level = 0; level < levels; level++) {
            NSUInteger uniform_offset;
            id<MTLBuffer> buffer =
                [commands uploadBytes:&layout[level].uniforms
                               length:sizeof(layout[level].uniforms)
                               offset:&uniform_offset
                                error:error];
            if (!buffer)
                return nil;
            uniforms[level] = buffer.gpuAddress + uniform_offset;
        }
    }
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    if (!e) {
        upload_error(error, @"Could not create Metal texture decode encoder");
        return nil;
    }
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    if (direct) {
        [e copyFromBuffer:data
                   sourceOffset:offset
              sourceBytesPerRow:shape->pitch
            sourceBytesPerImage:0
                     sourceSize:MTLSizeMake(td.width, td.height, 1)
                      toTexture:texture
               destinationSlice:0
               destinationLevel:0
              destinationOrigin:MTLOriginMake(0, 0, 0)];
    } else {
        id<MTL4ArgumentTable> arguments = blocks ? _blockArguments : _arguments;
        [e setComputePipelineState:blocks ? _blockPipeline : _pipeline];
        [arguments setAddress:faults.gpuAddress atIndex:4];
        [arguments setAddress:indexed ? palette.gpuAddress + paletteOffset :
                                         data.gpuAddress
                       atIndex:1];
        for (unsigned int face = 0; face < (shape->cubemap ? 6u : 1u); face++) {
            for (unsigned int level = 0; level < levels; level++) {
                TextureLevel l = layout[level];
                NV2AMetalTextureDecodeUniforms u = l.uniforms;
                [arguments setAddress:data.gpuAddress + offset +
                                       face * face_stride + l.offset
                               atIndex:0];
                [arguments setAddress:uniforms[level] atIndex:2];
                [arguments setAddress:scratch.gpuAddress atIndex:3];
                [e setArgumentTable:arguments];
                [e dispatchThreads:MTLSizeMake(blocks ? (u.width + 3) / 4 : u.width,
                                              blocks ? (u.height + 3) / 4 : u.height,
                                              u.depth)
                    threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                [e barrierAfterEncoderStages:MTLStageDispatch
                         beforeEncoderStages:MTLStageBlit
                           visibilityOptions:MTL4VisibilityOptionDevice];
                [e copyFromBuffer:scratch
                           sourceOffset:0
                      sourceBytesPerRow:(NSUInteger)u.output_row * output_bytes
                    sourceBytesPerImage:(NSUInteger)u.output_slice *
                                        output_bytes
                             sourceSize:MTLSizeMake(u.width, u.height, u.depth)
                              toTexture:texture
                       destinationSlice:face
                       destinationLevel:level
                      destinationOrigin:MTLOriginMake(0, 0, 0)];
                [e barrierAfterEncoderStages:MTLStageBlit
                         beforeEncoderStages:MTLStageDispatch
                           visibilityOptions:MTL4VisibilityOptionDevice];
            }
        }
    }
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return [[NV2AMetalTextureUploadResult alloc] initWithTexture:texture
                                                          faults:faults
                                                    sourceLength:source_length
                                                           shape:shape
                                                          format:f];
}
@end
