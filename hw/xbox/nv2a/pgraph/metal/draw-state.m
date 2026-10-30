/*
 * Native raster state from gl/draw.c and gl/constants.h
 * Copyright (c) 2015 Jannik Vogel
 * Copyright (c) 2020-2025 Matt Borgerson
 * SPDX-License-Identifier: LGPL-2.0-or-later
 */

#import "draw-state.h"
#import "lru-cache.h"

static BOOL draw_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.draw-state"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

static NSUInteger draw_min(NSUInteger a, NSUInteger b)
{
    return a < b ? a : b;
}

/* Original NV2A factor values, including the unused value 11. */
static const MTLBlendFactor factors[] = {
    MTLBlendFactorZero,
    MTLBlendFactorOne,
    MTLBlendFactorSourceColor,
    MTLBlendFactorOneMinusSourceColor,
    MTLBlendFactorSourceAlpha,
    MTLBlendFactorOneMinusSourceAlpha,
    MTLBlendFactorDestinationAlpha,
    MTLBlendFactorOneMinusDestinationAlpha,
    MTLBlendFactorDestinationColor,
    MTLBlendFactorOneMinusDestinationColor,
    MTLBlendFactorSourceAlphaSaturated,
    MTLBlendFactorZero,
    MTLBlendFactorBlendColor,
    MTLBlendFactorOneMinusBlendColor,
    MTLBlendFactorBlendAlpha,
    MTLBlendFactorOneMinusBlendAlpha,
};
static const MTLBlendOperation operations[] = {
    MTLBlendOperationSubtract, MTLBlendOperationReverseSubtract,
    MTLBlendOperationAdd,      MTLBlendOperationMin,
    MTLBlendOperationMax,      MTLBlendOperationReverseSubtract,
    MTLBlendOperationAdd,
};
static const MTLCompareFunction compares[] = {
    MTLCompareFunctionNever,        MTLCompareFunctionLess,
    MTLCompareFunctionEqual,        MTLCompareFunctionLessEqual,
    MTLCompareFunctionGreater,      MTLCompareFunctionNotEqual,
    MTLCompareFunctionGreaterEqual, MTLCompareFunctionAlways,
};
static const MTLStencilOperation stencil_ops[] = {
    MTLStencilOperationKeep,           MTLStencilOperationKeep,
    MTLStencilOperationZero,           MTLStencilOperationReplace,
    MTLStencilOperationIncrementClamp, MTLStencilOperationDecrementClamp,
    MTLStencilOperationInvert,         MTLStencilOperationIncrementWrap,
    MTLStencilOperationDecrementWrap,
};

BOOL nv2a_metal_draw_config_validate(const NV2AMetalDrawConfig *c,
                                     NSError **error)
{
    if (!c || (!c->viewport_width) != (!c->viewport_height) ||
        c->viewport_width > 16384 || c->viewport_height > 16384 ||
        (c->setup_raster & NV_PGRAPH_SETUPRASTER_FRONTFACEMODE) >
            NV_PGRAPH_SETUPRASTER_FRONTFACEMODE_LINE ||
        ((c->setup_raster & NV_PGRAPH_SETUPRASTER_BACKFACEMODE) >> 2) >
            NV_PGRAPH_SETUPRASTER_FRONTFACEMODE_LINE)
        return draw_error(error, @"Invalid native polygon configuration");
    BOOL blend = (c->blend & NV_PGRAPH_BLEND_EN) &&
                 !(c->blend & NV_PGRAPH_BLEND_LOGICOP_ENABLE);
    unsigned source = (c->blend & NV_PGRAPH_BLEND_SFACTOR) >> 4,
             destination = (c->blend & NV_PGRAPH_BLEND_DFACTOR) >> 8,
             equation = c->blend & NV_PGRAPH_BLEND_EQN;
    if (blend && (source == 11 || destination == 11 ||
                  equation >= sizeof(operations) / sizeof(*operations)))
        return draw_error(error, @"Invalid native blend configuration");
    if ((c->control[0] & NV_PGRAPH_CONTROL_0_ZENABLE) &&
        ((c->control[0] & NV_PGRAPH_CONTROL_0_ZFUNC) >> 16) > 7)
        return draw_error(error, @"Invalid native depth comparison");
    if (c->control[1] & NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE) {
        if (((c->control[1] & NV_PGRAPH_CONTROL_1_STENCIL_FUNC) >> 4) > 7)
            return draw_error(error, @"Invalid native stencil comparison");
        unsigned ops[] = {
            c->control[2] & NV_PGRAPH_CONTROL_2_STENCIL_OP_FAIL,
            (c->control[2] & NV_PGRAPH_CONTROL_2_STENCIL_OP_ZFAIL) >> 4,
            (c->control[2] & NV_PGRAPH_CONTROL_2_STENCIL_OP_ZPASS) >> 8,
        };
        for (unsigned i = 0; i < 3; i++)
            if (ops[i] < 1 || ops[i] > 8)
                return draw_error(error, @"Invalid native stencil operation");
    }
    if ((c->setup_raster & NV_PGRAPH_SETUPRASTER_CULLENABLE) &&
        !(c->setup_raster & NV_PGRAPH_SETUPRASTER_CULLCTRL))
        return draw_error(error, @"Invalid native cull configuration");
    return YES;
}

/* Keys contain effective descriptor scalars, never padded capture bytes.
 * Stencil reference and all other dynamic raster state stay in the capture. */
static uint64_t depth_stencil_key(const NV2AMetalDrawConfig *c)
{
    uint32_t z = c->control[0], s = c->control[1], ops = c->control[2];
    BOOL depth = !!(z & NV_PGRAPH_CONTROL_0_ZENABLE);
    uint64_t key = depth ? (z & NV_PGRAPH_CONTROL_0_ZFUNC) >> 16 : 7;
    key |= (uint64_t)(depth && (z & NV_PGRAPH_CONTROL_0_ZWRITEENABLE)) << 3;
    if (s & NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE) {
        key |= UINT64_C(1) << 4;
        key |= (uint64_t)((s & NV_PGRAPH_CONTROL_1_STENCIL_FUNC) >> 4) << 5;
        key |= (uint64_t)(ops & NV_PGRAPH_CONTROL_2_STENCIL_OP_FAIL) << 8;
        key |= (uint64_t)((ops & NV_PGRAPH_CONTROL_2_STENCIL_OP_ZFAIL) >> 4)
               << 12;
        key |= (uint64_t)((ops & NV_PGRAPH_CONTROL_2_STENCIL_OP_ZPASS) >> 8)
               << 16;
        key |= (uint64_t)((s & NV_PGRAPH_CONTROL_1_STENCIL_MASK_READ) >> 16)
               << 20;
        key |= (uint64_t)((s & NV_PGRAPH_CONTROL_1_STENCIL_MASK_WRITE) >> 24)
               << 28;
    }
    return key;
}

@interface NV2AMetalDepthStencilCache ()
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (id<MTLDepthStencilState>)stateForKey:(uint64_t)key error:(NSError **)error;
@end
@implementation NV2AMetalDepthStencilCache {
    id<MTLDevice> _device;
    NV2AMetalLRUCache<NSNumber *, id<MTLDepthStencilState>> *_states;
    uint64_t _buildCount;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device
{
    self = [super init];
    if (self) {
        _device = device;
        _states = [[NV2AMetalLRUCache alloc] initWithCapacity:256];
    }
    return self;
}
+ (instancetype)sharedWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    if (!device.hasUnifiedMemory ||
        ![device supportsFamily:MTLGPUFamilyApple7] ||
        ![device supportsFamily:MTLGPUFamilyMetal4]) {
        draw_error(error,
                   @"Depth/stencil cache requires Apple Silicon Metal 4");
        return nil;
    }
    static NSMapTable *caches;
    @synchronized(NV2AMetalDepthStencilCache.class) {
        if (!caches)
            caches = [[NSMapTable alloc]
                initWithKeyOptions:NSPointerFunctionsWeakMemory |
                                   NSPointerFunctionsObjectPointerPersonality
                      valueOptions:NSPointerFunctionsWeakMemory
                          capacity:1];
        NV2AMetalDepthStencilCache *cache = [caches objectForKey:device];
        if (!cache) {
            cache = [[self alloc] initWithDevice:device];
            [caches setObject:cache forKey:device];
        }
        return cache;
    }
}
- (id<MTLDepthStencilState>)newStateWithDescriptor:
    (MTLDepthStencilDescriptor *)descriptor
{
    _buildCount++;
    return [_device newDepthStencilStateWithDescriptor:descriptor];
}
- (id<MTLDepthStencilState>)stateForKey:(uint64_t)key error:(NSError **)error
{
    @synchronized(self) {
        NSNumber *boxed = @(key);
        id<MTLDepthStencilState> state = _states[boxed];
        if (state)
            return state;
        MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
        ds.depthCompareFunction = compares[key & 7];
        ds.depthWriteEnabled = !!(key & 8);
        if (key & 16) {
            MTLStencilDescriptor *stencil = [MTLStencilDescriptor new];
            stencil.stencilCompareFunction = compares[(key >> 5) & 7];
            stencil.stencilFailureOperation = stencil_ops[(key >> 8) & 15];
            stencil.depthFailureOperation = stencil_ops[(key >> 12) & 15];
            stencil.depthStencilPassOperation = stencil_ops[(key >> 16) & 15];
            stencil.readMask = (key >> 20) & 255;
            stencil.writeMask = (key >> 28) & 255;
            ds.frontFaceStencil = ds.backFaceStencil = stencil;
        }
        state = [self newStateWithDescriptor:ds];
        if (!state) {
            draw_error(error, @"Cannot create native depth/stencil state");
            return nil;
        }
        _states[boxed] = state;
        return state;
    }
}
@end

@implementation NV2AMetalDrawState {
    NV2AMetalDrawConfig _config;
    NV2AMetalDepthStencilCache *_depthStencilCache;
    MTLColorWriteMask _writeMask;
    unsigned int _sourceFactor, _destinationFactor, _equation;
    MTLCullMode _cullMode;
    BOOL _blendEnabled, _cullBoth;
    MTLWinding _frontFace;
}

- (NV2AMetalDrawConfig)config
{
    return _config;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                        config:(const NV2AMetalDrawConfig *)c
                         error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }
    if (!c || !device.hasUnifiedMemory ||
        ![device supportsFamily:MTLGPUFamilyApple7] ||
        ![device supportsFamily:MTLGPUFamilyMetal4]) {
        draw_error(error, @"Draw state requires Apple Silicon Metal 4");
        return nil;
    }
    if (!nv2a_metal_draw_config_validate(c, error))
        return nil;
    _device = device;
    _config = *c;
    unsigned int control0 = c->control[0], control1 = c->control[1];
    if ((c->setup_raster & NV_PGRAPH_SETUPRASTER_FRONTFACEMODE) >
            NV_PGRAPH_SETUPRASTER_FRONTFACEMODE_LINE ||
        ((c->setup_raster & NV_PGRAPH_SETUPRASTER_BACKFACEMODE) >> 2) >
            NV_PGRAPH_SETUPRASTER_FRONTFACEMODE_LINE) {
        draw_error(error, @"Invalid polygon mode");
        return nil;
    }
    _writeMask = MTLColorWriteMaskNone;
    if (control0 & NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE) {
        _writeMask |= MTLColorWriteMaskRed;
    }
    if (control0 & NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE) {
        _writeMask |= MTLColorWriteMaskGreen;
    }
    if (control0 & NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE) {
        _writeMask |= MTLColorWriteMaskBlue;
    }
    if (control0 & NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE) {
        _writeMask |= MTLColorWriteMaskAlpha;
    }
    _ditherEnabled = !!(control0 & NV_PGRAPH_CONTROL_0_DITHERENABLE);
    _blendWord = c->blend;
    _blendColor = c->blend_color;
    _logicEnabled = !!(c->blend & NV_PGRAPH_BLEND_LOGICOP_ENABLE);
    _logicOperation = (c->blend & NV_PGRAPH_BLEND_LOGICOP) >> 12;
    /* Logic ops bypass blending, including on floating-point attachments. */
    _blendEnabled = !!(c->blend & NV_PGRAPH_BLEND_EN) && !_logicEnabled;
    _sourceFactor = (c->blend & NV_PGRAPH_BLEND_SFACTOR) >> 4;
    _destinationFactor = (c->blend & NV_PGRAPH_BLEND_DFACTOR) >> 8;
    _equation = c->blend & NV_PGRAPH_BLEND_EQN;
    if (_blendEnabled &&
        (_sourceFactor == 11 || _destinationFactor == 11 ||
         _equation >= sizeof(operations) / sizeof(*operations))) {
        draw_error(error, @"Invalid NV2A blend factors/equation");
        return nil;
    }
    /* Min/max ignore factors; disabled blending ignores all blend words. */
    unsigned int effective = 0;
    if (_blendEnabled) {
        effective = NV_PGRAPH_BLEND_EN | (unsigned int)operations[_equation];
        if (_equation != 3 && _equation != 4) {
            effective |= _sourceFactor << 4 | _destinationFactor << 8;
        }
    }
    _pipelineKey = effective | (NSUInteger)_writeMask << 17 |
                   (NSUInteger)_logicEnabled << 21 |
                   (NSUInteger)_ditherEnabled << 22;
    _requiresDepth = !!(control0 & NV_PGRAPH_CONTROL_0_ZENABLE);
    _requiresStencil = !!(control1 & NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE);
    /* Validation precedes every lookup, including warm hits. Disabling depth
     * also disables writing; inactive stencil words do not affect the key. */
    _depthStencilCache = [NV2AMetalDepthStencilCache sharedWithDevice:device
                                                                error:error];
    _depthStencil = [_depthStencilCache stateForKey:depth_stencil_key(c)
                                              error:error];
    if (!_depthStencil)
        return nil;
    /* Native vertex processing reverses GL clip-space Y. */
    _frontFace = c->setup_raster & NV_PGRAPH_SETUPRASTER_FRONTFACE ?
                     MTLWindingCounterClockwise :
                     MTLWindingClockwise;
    _cullMode = MTLCullModeNone;
    if (c->setup_raster & NV_PGRAPH_SETUPRASTER_CULLENABLE) {
        unsigned int face =
            (c->setup_raster & NV_PGRAPH_SETUPRASTER_CULLCTRL) >> 21;
        if (!face) {
            draw_error(error, @"Invalid NV2A cull mode");
            return nil;
        }
        _cullBoth = face == NV_PGRAPH_SETUPRASTER_CULLCTRL_FRONT_AND_BACK;
        _cullMode = face == NV_PGRAPH_SETUPRASTER_CULLCTRL_FRONT ?
                        MTLCullModeFront :
                        MTLCullModeBack;
    }
    return self;
}

- (MTL4RenderPipelineColorAttachmentDescriptor *)colorAttachment
{
    MTL4RenderPipelineColorAttachmentDescriptor *a =
        [MTL4RenderPipelineColorAttachmentDescriptor new];
    a.writeMask = _writeMask;
    if (_blendEnabled) {
        a.blendingState = MTL4BlendStateEnabled;
        a.sourceRGBBlendFactor = a.sourceAlphaBlendFactor =
            factors[_sourceFactor];
        a.destinationRGBBlendFactor = a.destinationAlphaBlendFactor =
            factors[_destinationFactor];
        a.rgbBlendOperation = a.alphaBlendOperation = operations[_equation];
    }
    return a;
}

- (BOOL)applyToEncoder:(id<MTL4RenderCommandEncoder>)encoder
                 width:(NSUInteger)width
                height:(NSUInteger)height
             primitive:(MTLPrimitiveType)primitive
{
    return [self applyToEncoder:encoder
                          width:width
                         height:height
                      primitive:primitive
           ignorePolygonCulling:NO];
}
- (BOOL)applyToEncoder:(id<MTL4RenderCommandEncoder>)encoder
                   width:(NSUInteger)width
                  height:(NSUInteger)height
               primitive:(MTLPrimitiveType)primitive
    ignorePolygonCulling:(BOOL)ignore
{
    if (_config.viewport_width) {
        [encoder setViewport:(MTLViewport){ 0, 0, _config.viewport_width,
                                            _config.viewport_height, 0, 1 }];
    }
    [encoder setDepthStencilState:_depthStencil];
    [encoder setStencilReferenceValue:(_config.control[1] &
                                       NV_PGRAPH_CONTROL_1_STENCIL_REF) >>
                                      8];
    [encoder setCullMode:ignore ? MTLCullModeNone : _cullMode];
    [encoder setFrontFacingWinding:_frontFace];
    uint32_t argb = _config.blend_color;
    [encoder setBlendColorRed:((argb >> 16) & 255) / 255.0f
                        green:((argb >> 8) & 255) / 255.0f
                         blue:(argb & 255) / 255.0f
                        alpha:(argb >> 24) / 255.0f];
    if (!ignore && _cullBoth && primitive >= MTLPrimitiveTypeTriangle) {
        return NO;
    }
    MTLScissorRect rect = { 0, 0, width, height };
    if (_config.scissor_enabled) {
        rect.x = draw_min(_config.scissor.x, width);
        rect.y = draw_min(_config.scissor.y, height);
        rect.width = draw_min(_config.scissor.width, width - rect.x);
        rect.height = draw_min(_config.scissor.height, height - rect.y);
    }
    if (!rect.width || !rect.height) {
        return NO;
    }
    [encoder setScissorRect:rect];
    return YES;
}
@end
