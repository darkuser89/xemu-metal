/* Native VGA graphics decode; source pixels remain GPU-readable.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "vga.h"
#include "vga-source.h"
_Static_assert(sizeof(NV2AMetalVGAUniforms) == 1096, "VGA CPU/MSL ABI");
static BOOL vga_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.vga"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}
@implementation NV2AMetalVGA {
    id<MTLDevice> _device;
    id<MTLComputePipelineState> _pipeline;
    id<MTL4ArgumentTable> _arguments;
    NV2AMetalVGATargetAllocator _targetAllocator;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    return [self initWithDevice:device targetAllocator:nil error:error];
}
- (instancetype)initWithDevice:(id<MTLDevice>)device
                targetAllocator:(NV2AMetalVGATargetAllocator)allocator
                          error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    if (!device.hasUnifiedMemory ||
        ![device supportsFamily:MTLGPUFamilyApple7] ||
        ![device supportsFamily:MTLGPUFamilyMetal4]) {
        vga_error(error, @"VGA decode requires Apple Silicon Metal4");
        return nil;
    }
    _device = device;
    _targetAllocator = [allocator copy];
    return self;
}
- (BOOL)prepareDecoderWithError:(NSError **)error
{
    if (_pipeline)
        return YES;
    id<MTLDevice> device = _device;
    id<MTL4Compiler> compiler =
        [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                    error:error];
    if (!compiler)
        return NO;
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = @(metal_shader_source);
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    id<MTLLibrary> lib = [compiler newLibraryWithDescriptor:ld error:error];
    if (!lib)
        return NO;
    MTL4LibraryFunctionDescriptor *fn = [MTL4LibraryFunctionDescriptor new];
    fn.library = lib;
    fn.name = @"nv2a_vga_graphics";
    MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
    pd.computeFunctionDescriptor = fn;
    id<MTLComputePipelineState> pipeline =
        [compiler newComputePipelineStateWithDescriptor:pd
                                    compilerTaskOptions:nil
                                                  error:error];
    if (!pipeline)
        return NO;
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 3;
    ad.maxTextureBindCount = 1;
    ad.initializeBindings = YES;
    id<MTL4ArgumentTable> arguments =
        [device newArgumentTableWithDescriptor:ad error:error];
    if (!arguments)
        return NO;
    _pipeline = pipeline;
    _arguments = arguments;
    return YES;
}
- (id<MTLTexture>)encodeData:(id<MTLBuffer>)data
                        rows:(const NV2AMetalVGARow *)rows
                    uniforms:(const NV2AMetalVGAUniforms *)u
                    commands:(NV2AMetalCommands *)commands
                       error:(NSError **)error
{
    if (!u || !rows || !commands.commandBuffer || commands.device != _device ||
        data.device != _device || !u->width || !u->height || u->width > 16384 ||
        u->height > 16384 || u->duplicate > 1 || u->big_endian > 1 ||
        u->memory_mask < 3 || u->memory_mask == UINT32_MAX ||
        ((u->memory_mask + 1) & u->memory_mask) ||
        (uint64_t)u->memory_mask + 1 > data.length ||
        (u->mode != 0 && u->mode != 1 && u->mode != 2 && u->mode != 4 &&
         u->mode != 8 && u->mode != 15 && u->mode != 16 && u->mode != 24 &&
         u->mode != 32 && u->mode != 255)) {
        vga_error(error, @"Invalid VGA graphics metadata or VRAM bounds");
        return nil;
    }
    if (u->mode == 1 &&
        (!u->text_columns ||
         (u->character_width != 8 && u->character_width != 9 &&
          u->character_width != 16) ||
         !u->character_height || u->character_height > 32 ||
         (uint64_t)u->text_columns * u->character_width != u->width ||
         u->font_offset[0] > data.length ||
         32765 > data.length - u->font_offset[0] ||
         u->font_offset[1] > data.length ||
         32765 > data.length - u->font_offset[1] || u->cursor_visible > 1 ||
         u->line_graphics > 1)) {
        vga_error(error, @"Invalid VGA text/font metadata");
        return nil;
    }
    for (unsigned y = 0; y < u->height; y++) {
        if (rows[y].hpel > (u->mode == 1 ? u->character_height - 1 : 7) ||
            (u->mode == 1 &&
             ((uint64_t)rows[y].address + (u->text_columns - 1) * 4 + 2 >
              data.length))) {
            vga_error(error, @"Invalid VGA row/panning or character span");
            return nil;
        }
    }
    if (![self prepareDecoderWithError:error])
        return nil;
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:u->width
                                    height:u->height
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> target = _targetAllocator ? _targetAllocator(td) :
        [_device newTextureWithDescriptor:td];
    if (!target) {
        vga_error(error, @"Cannot allocate native VGA decode target");
        return nil;
    }
    if (_targetAllocator &&
        (target.device != _device || target.width != td.width ||
         target.height != td.height || target.pixelFormat != td.pixelFormat ||
         target.storageMode != td.storageMode || target.usage != td.usage ||
         target.textureType != td.textureType || target.sampleCount != 1 ||
         target.mipmapLevelCount != 1)) {
        vga_error(error, @"Incompatible native VGA decode target");
        return nil;
    }
    NSUInteger row_offset, uniform_offset;
    id<MTLBuffer> row_buffer = [commands uploadBytes:rows
                                              length:u->height * sizeof(*rows)
                                              offset:&row_offset
                                               error:error];
    if (!row_buffer)
        return nil;
    id<MTLBuffer> constants = [commands uploadBytes:u
                                             length:sizeof(*u)
                                             offset:&uniform_offset
                                              error:error];
    if (!constants || ![commands addResource:data error:error] ||
        ![commands addResource:target error:error] ||
        ![commands keepAlive:self error:error])
        return nil;
    [_arguments setAddress:data.gpuAddress atIndex:0];
    [_arguments setAddress:row_buffer.gpuAddress + row_offset atIndex:1];
    [_arguments setAddress:constants.gpuAddress + uniform_offset atIndex:2];
    [_arguments setTexture:target.gpuResourceID atIndex:0];
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    if (!e) {
        vga_error(error, @"Cannot create VGA compute encoder");
        return nil;
    }
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageDispatch
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setComputePipelineState:_pipeline];
    [e setArgumentTable:_arguments];
    [e dispatchThreads:MTLSizeMake(u->width, u->height, 1)
        threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [e barrierAfterStages:MTLStageDispatch
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return target;
}
@end
