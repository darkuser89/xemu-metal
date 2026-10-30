/* SPDX-License-Identifier: LGPL-2.0-or-later */

#import "texture-sampler.h"
#import "texture-storage.h"

_Static_assert(sizeof(NV2AMetalSamplingUniforms) == 52, "CPU/MSL sampling");

static BOOL sampler_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.texture-sampler"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

BOOL nv2a_metal_sampling_validate(const NV2AMetalSamplingUniforms *s,
                                  NSError **error)
{
    if (!s || s->enabled != 1 || s->min_linear > 1 || s->mag_linear > 1 ||
        s->mip_filter > 2 ||
        (s->anisotropy != 1 && s->anisotropy != 2 && s->anisotropy != 4 &&
         s->anisotropy != 8) ||
        !isfinite(s->lod_bias) || s->lod_bias < -16 ||
        s->lod_bias > 4095.f / 256)
        return sampler_error(error, @"Invalid restored manual sampling state");
    for (unsigned i = 0; i < 3; i++)
        if (s->address[i] < NV_PGRAPH_TEXADDRESS0_ADDRU_WRAP ||
            s->address[i] > NV_PGRAPH_TEXADDRESS0_ADDRU_CLAMP_OGL)
            return sampler_error(error, @"Invalid restored texture address");
    for (unsigned i = 0; i < 4; i++)
        if (!isfinite(s->border_color[i]))
            return sampler_error(error, @"Invalid restored border color");
    return YES;
}

/* Only formats supported by the native color/decoded-texture path. Integer,
 * depth and compressed resources require different shader read contracts. */
static BOOL sampleable(MTLPixelFormat format)
{
    switch (format) {
    case MTLPixelFormatR8Unorm:
    case MTLPixelFormatR8Snorm:
    case MTLPixelFormatRG8Unorm:
    case MTLPixelFormatRG8Snorm:
    case MTLPixelFormatRGBA8Unorm:
    case MTLPixelFormatRGBA8Snorm:
    case MTLPixelFormatBGRA8Unorm:
    case MTLPixelFormatB5G6R5Unorm:
    case MTLPixelFormatBGR5A1Unorm:
    case MTLPixelFormatABGR4Unorm:
    case MTLPixelFormatR16Float:
    case MTLPixelFormatRG16Float:
    case MTLPixelFormatRGBA16Float:
    case MTLPixelFormatR32Float:
    case MTLPixelFormatRG32Float:
    case MTLPixelFormatRGBA32Float:
        return YES;
    default:
        return NO;
    }
}

float nv2a_metal_texture_lod_bias(unsigned int filter)
{
    unsigned int raw = filter & NV_PGRAPH_TEXFILTER0_MIPMAP_LOD_BIAS;
    int value = raw & 0x1000 ? (int)raw - 0x2000 : (int)raw;
    return value / 256.0f;
}

@implementation NV2AMetalTextureBinding
- (instancetype)initWithTexture:(id<MTLTexture>)texture
                        sampler:(id<MTLSamplerState>)sampler
                       sampling:(NV2AMetalSamplingUniforms)sampling
{
    self = [super init];
    if (self) {
        _texture = texture;
        _sampler = sampler;
        _sampling = sampling;
    }
    return self;
}
@end

@implementation NV2AMetalTextureSampler {
    id<MTLDevice> _device;
    id<MTLSamplerState> _sampler;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }
    if (!device.hasUnifiedMemory ||
        ![device supportsFamily:MTLGPUFamilyApple7] ||
        ![device supportsFamily:MTLGPUFamilyMetal4]) {
        sampler_error(error,
                      @"Texture sampling requires Apple Silicon Metal 4");
        return nil;
    }
    _device = device;
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
    sd.sAddressMode = sd.tAddressMode = sd.rAddressMode =
        MTLSamplerAddressModeClampToEdge;
    sd.supportArgumentBuffers = YES;
    _sampler = [device newSamplerStateWithDescriptor:sd];
    if (!_sampler) {
        sampler_error(error, @"Cannot create native Metal sampler");
        return nil;
    }
    return self;
}

- (NV2AMetalTextureBinding *)
    bindingForSnapshotTexture:(id<MTLTexture>)texture
                     sampling:(const NV2AMetalSamplingUniforms *)sampling
                        error:(NSError **)error
{
    MTLTextureType type = texture.textureType;
    if (texture.device != _device ||
        !nv2a_metal_texture_storage(texture, NULL) ||
        texture.sampleCount != 1 ||
        !(texture.usage & MTLTextureUsageShaderRead) ||
        (type != MTLTextureType2D && type != MTLTextureType3D &&
         type != MTLTextureTypeCube) ||
        !nv2a_metal_sampling_validate(sampling, error)) {
        sampler_error(error, @"Invalid restored native texture binding");
        return nil;
    }
    return [[NV2AMetalTextureBinding alloc] initWithTexture:texture
                                                    sampler:_sampler
                                                   sampling:*sampling];
}
- (NV2AMetalTextureBinding *)bindingForTexture:(id<MTLTexture>)texture
                                        config:(const NV2AMetalSamplerConfig *)c
                                         error:(NSError **)error
{
    MTLTextureType type = texture.textureType;
    if (!c || c->signed_channels > 15 || texture.device != _device ||
        texture.sampleCount != 1 ||
        !(texture.usage & MTLTextureUsageShaderRead) ||
        !sampleable(texture.pixelFormat) ||
        (type != MTLTextureType2D && type != MTLTextureType3D &&
         type != MTLTextureTypeCube) ||
        (c->rectangle && type != MTLTextureType2D) ||
        c->min_level > c->max_level ||
        c->max_level >= texture.mipmapLevelCount ||
        (c->rectangle && (c->min_level || c->max_level)) ||
        (c->anisotropy != 1 && c->anisotropy != 2 && c->anisotropy != 4 &&
         c->anisotropy != 8)) {
        sampler_error(error, @"Invalid native texture sampler configuration");
        return nil;
    }
    unsigned min = (c->filter & NV_PGRAPH_TEXFILTER0_MIN) >> 16;
    unsigned mag = (c->filter & NV_PGRAPH_TEXFILTER0_MAG) >> 24;
    if (min < NV_PGRAPH_TEXFILTER0_MIN_BOX_LOD0 ||
        min > NV_PGRAPH_TEXFILTER0_MIN_CONVOLUTION_2D_LOD0 ||
        (mag != 1 && mag != 2 && mag != 4)) {
        sampler_error(error, @"Unsupported NV2A texture filter");
        return nil;
    }
    NV2AMetalSamplingUniforms s = { 0 };
    s.enabled = 1;
    s.address[0] = c->address & NV_PGRAPH_TEXADDRESS0_ADDRU;
    s.address[1] = (c->address & NV_PGRAPH_TEXADDRESS0_ADDRV) >> 8;
    s.address[2] = type == MTLTextureType3D ?
                       (c->address & NV_PGRAPH_TEXADDRESS0_ADDRP) >> 16 :
                       NV_PGRAPH_TEXADDRESS0_ADDRU_CLAMP_TO_EDGE;
    for (unsigned i = 0; i < 3; i++) {
        if (s.address[i] < NV_PGRAPH_TEXADDRESS0_ADDRU_WRAP ||
            s.address[i] > NV_PGRAPH_TEXADDRESS0_ADDRU_CLAMP_OGL) {
            sampler_error(error, @"Unsupported NV2A texture address mode");
            return nil;
        }
    }
    s.min_linear = min == 2 || min == 4 || min == 6 || min == 7;
    s.mag_linear = mag != 1;
    s.mip_filter = c->rectangle         ? 0 :
                   min == 3 || min == 4 ? 1 :
                   min == 5 || min == 6 ? 2 :
                                          0;
    s.anisotropy = c->anisotropy;
    s.lod_bias = nv2a_metal_texture_lod_bias(c->filter);
    if (!c->bordered) {
        s.border_color[0] = ((c->border_color >> 16) & 255) / 255.0f;
        s.border_color[1] = ((c->border_color >> 8) & 255) / 255.0f;
        s.border_color[2] = (c->border_color & 255) / 255.0f;
        s.border_color[3] = (c->border_color >> 24) / 255.0f;
        for (unsigned k = 0; k < 4; k++) {
            if (c->signed_channels & (1u << k)) {
                int raw = (int)lroundf(s.border_color[k] * 255.0f);
                s.border_color[k] = (raw >= 128 ? raw - 256 : raw) / 128.0f;
            }
        }
    }
    if (c->hilo16 && c->signed_channels == 15 && !c->bordered) {
        // HILO has two components; B mirrors LO and alpha remains opaque.
        s.border_color[2] = s.border_color[1];
        s.border_color[3] = 1;
    }
    if (c->min_level || c->max_level + 1 != texture.mipmapLevelCount) {
        if (!(texture.usage & MTLTextureUsagePixelFormatView)) {
            sampler_error(error, @"Mip range requires a texture view");
            return nil;
        }
        texture = [texture
            newTextureViewWithPixelFormat:texture.pixelFormat
                              textureType:type
                                   levels:NSMakeRange(c->min_level,
                                                      c->max_level -
                                                          c->min_level + 1)
                                   slices:NSMakeRange(
                                              0, type == MTLTextureTypeCube ?
                                                     6 :
                                                     1)];
        if (!texture) {
            sampler_error(error,
                          @"Cannot create native mip-range texture view");
            return nil;
        }
    }
    return [[NV2AMetalTextureBinding alloc] initWithTexture:texture
                                                    sampler:_sampler
                                                   sampling:s];
}
@end
