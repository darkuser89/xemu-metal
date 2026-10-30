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
}
- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
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
    id<MTL4Compiler> compiler =
        [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                    error:error];
    if (!compiler)
        return nil;
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = @(metal_shader_source);
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    id<MTLLibrary> lib = [compiler newLibraryWithDescriptor:ld error:error];
    if (!lib)
        return nil;
    MTL4LibraryFunctionDescriptor *fn = [MTL4LibraryFunctionDescriptor new];
    fn.library = lib;
    fn.name = @"nv2a_vga_graphics";
    MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
    pd.computeFunctionDescriptor = fn;
    _pipeline = [compiler newComputePipelineStateWithDescriptor:pd
                                            compilerTaskOptions:nil
                                                          error:error];
    if (!_pipeline)
        return nil;
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 3;
    ad.maxTextureBindCount = 1;
    ad.initializeBindings = YES;
    _arguments = [device newArgumentTableWithDescriptor:ad error:error];
    return _arguments ? self : nil;
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
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:u->width
                                    height:u->height
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> target = [_device newTextureWithDescriptor:td];
    id<MTLBuffer> row_buffer =
        [_device newBufferWithBytes:rows
                             length:u->height * sizeof(*rows)
                            options:MTLResourceStorageModeShared];
    id<MTLBuffer> constants =
        [_device newBufferWithBytes:u
                             length:sizeof(*u)
                            options:MTLResourceStorageModeShared];
    if (!target || !row_buffer || !constants) {
        vga_error(error, @"Cannot allocate native VGA decode resources");
        return nil;
    }
    if (![commands addResource:data error:error] ||
        ![commands addResource:target error:error] ||
        ![commands addResource:row_buffer error:error] ||
        ![commands addResource:constants error:error] ||
        ![commands keepAlive:self error:error])
        return nil;
    [_arguments setAddress:data.gpuAddress atIndex:0];
    [_arguments setAddress:row_buffer.gpuAddress atIndex:1];
    [_arguments setAddress:constants.gpuAddress atIndex:2];
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
