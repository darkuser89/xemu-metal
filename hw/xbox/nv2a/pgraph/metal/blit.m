/* Native byte blits from gl/blit.c.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "blit.h"
#include "blit-types.h"
#include "blit-source.h"
#include <unistd.h>
_Static_assert(sizeof(NV2AMetalBlitUniforms) == 64, "CPU/MSL blit ABI");
static BOOL blit_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.blit"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}
static uint64_t extent(unsigned rows, unsigned pitch, uint64_t full,
                       uint64_t tail)
{
    uint64_t length = rows && full ? (uint64_t)(rows - 1) * pitch + full : 0;
    return tail ? MAX(length, (uint64_t)rows * pitch + tail) : length;
}
BOOL nv2a_metal_blit_layout(const NV2AMetalBlitConfig *c,
                            NV2AMetalBlitLayout *out, NSError **error)
{
    if (!c)
        return blit_error(error, @"Missing blit configuration");
    NV2AMetalBlitLayout l = { 0 };
    switch (c->format) {
    case NV062_SET_COLOR_FORMAT_LE_Y8:
        l.bytes_per_pixel = 1;
        break;
    case NV062_SET_COLOR_FORMAT_LE_R5G6B5:
        l.bytes_per_pixel = 2;
        break;
    case NV062_SET_COLOR_FORMAT_LE_A8R8G8B8:
    case NV062_SET_COLOR_FORMAT_LE_Y32:
        l.bytes_per_pixel = 4;
        break;
    case NV062_SET_COLOR_FORMAT_LE_X8R8G8B8:
        l.bytes_per_pixel = 4;
        l.patch_alpha = YES;
        l.alpha_value = 255;
        break;
    case NV062_SET_COLOR_FORMAT_LE_X8R8G8B8_Z8R8G8B8:
        l.bytes_per_pixel = 4;
        l.patch_alpha = YES;
        break;
    default:
        return blit_error(error, @"Unsupported NV2A blit format");
    }
    if ((c->operation != NV09F_SET_OPERATION_SRCCOPY &&
         c->operation != NV09F_SET_OPERATION_BLEND_AND) ||
        (c->operation == NV09F_SET_OPERATION_BLEND_AND &&
         c->beta >> 16 > 0x7f80) ||
        (c->rows &&
         (!c->source_pitch || !c->destination_pitch ||
          c->row_bytes > MIN(c->source_pitch, c->destination_pitch) ||
          c->row_bytes % l.bytes_per_pixel)))
        return blit_error(error, @"Invalid blit operation, beta or row layout");
    uint64_t full = c->row_bytes, tail = c->tail_bytes;
    uint64_t write_full = full, write_tail = tail;
    if (c->operation == NV09F_SET_OPERATION_BLEND_AND) {
        full = full / l.bytes_per_pixel;
        tail = tail / l.bytes_per_pixel;
        write_full = full ? full * 4 - (l.patch_alpha ? 0 : 1) : 0;
        write_tail = tail ? tail * 4 - (l.patch_alpha ? 0 : 1) : 0;
        full = full ? full * 4 - 1 : 0;
        tail = tail ? tail * 4 - 1 : 0;
    }
    uint64_t read_span = extent(c->rows, c->source_pitch, full, tail);
    uint64_t write_span =
        extent(c->rows, c->destination_pitch, write_full, write_tail);
    if (read_span > UINT32_MAX - c->source_offset ||
        write_span > UINT32_MAX - c->destination_offset)
        return blit_error(error, @"Blit address span exceeds native range");
    l.source_length = (NSUInteger)read_span;
    l.destination_length = (NSUInteger)write_span;
    if (out)
        *out = l;
    return YES;
}
@implementation NV2AMetalBlit {
    id<MTLDevice> _device;
    id<MTLComputePipelineState> _parallel, _serial, _alpha;
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
        blit_error(error, @"Blits require Apple Silicon Metal 4");
        return nil;
    }
    _device = device;
    id<MTL4Compiler> compiler =
        [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                    error:error];
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = @(metal_shader_source);
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld error:error];
    if (!compiler || !library)
        return nil;
    for (unsigned i = 0; i < 3; i++) {
        MTL4LibraryFunctionDescriptor *fn = [MTL4LibraryFunctionDescriptor new];
        fn.library = library;
        fn.name = i == 0 ? @"nv2a_blit_parallel" :
                  i == 1 ? @"nv2a_blit_serial" :
                           @"nv2a_blit_alpha";
        MTL4ComputePipelineDescriptor *pd = [MTL4ComputePipelineDescriptor new];
        pd.computeFunctionDescriptor = fn;
        id<MTLComputePipelineState> pipeline =
            [compiler newComputePipelineStateWithDescriptor:pd
                                        compilerTaskOptions:nil
                                                      error:error];
        if (!pipeline)
            return nil;
        if (i == 0)
            _parallel = pipeline;
        else if (i == 1)
            _serial = pipeline;
        else
            _alpha = pipeline;
    }
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 3;
    ad.initializeBindings = YES;
    _arguments = [device newArgumentTableWithDescriptor:ad error:error];
    return _arguments ? self : nil;
}
- (BOOL)encodeSource:(id<MTLBuffer>)source
         destination:(id<MTLBuffer>)dest
              config:(const NV2AMetalBlitConfig *)c
            commands:(NV2AMetalCommands *)commands
               error:(NSError **)error
{
    NV2AMetalBlitLayout l;
    if (!nv2a_metal_blit_layout(c, &l, error))
        return NO;
    if (!commands.commandBuffer || commands.device != _device ||
        source.device != _device || dest.device != _device ||
        c->source_offset > source.length ||
        l.source_length > source.length - c->source_offset ||
        c->destination_offset > dest.length ||
        l.destination_length > dest.length - c->destination_offset)
        return blit_error(error, @"Invalid blit buffers or command context");
    if (!l.source_length && !l.destination_length)
        return YES;
    uint64_t sa = source.gpuAddress + c->source_offset;
    uint64_t da = dest.gpuAddress + c->destination_offset;
    if (source.storageMode == MTLStorageModeShared &&
        dest.storageMode == MTLStorageModeShared) {
        sa = (uintptr_t)source.contents + c->source_offset;
        da = (uintptr_t)dest.contents + c->destination_offset;
    }
    BOOL alias = sa < da + l.destination_length && da < sa + l.source_length;
    id<MTLBuffer> read_buffer = source, write_buffer = dest;
    unsigned read_offset = c->source_offset,
             write_offset = c->destination_offset;
    if (alias && source != dest && source.storageMode == MTLStorageModeShared &&
        dest.storageMode == MTLStorageModeShared) {
        /* Distinct NoCopy mappings may have distinct GPU virtual addresses.
         * One mapping is required for serial read-after-write dependencies. */
        uint64_t sb = (uintptr_t)source.contents, db = (uintptr_t)dest.contents;
        uint64_t base;
        if (da >= sb && da - sb <= source.length &&
            l.destination_length <= source.length - (da - sb)) {
            write_buffer = source;
            base = sb;
        } else if (sa >= db && sa - db <= dest.length &&
                   l.source_length <= dest.length - (sa - db)) {
            read_buffer = dest;
            base = db;
        } else {
            uint64_t page = (unsigned)getpagesize();
            base = MIN(sa, da) / page * page;
            uint64_t end =
                (MAX(sa + l.source_length, da + l.destination_length) + page -
                 1) /
                page * page;
            if (base < MIN(sb, db) ||
                end > MAX(sb + source.length, db + dest.length) ||
                end - base > UINT32_MAX)
                return blit_error(error, @"Cannot cover shared blit aliases "
                                         @"with an aligned GPU view");
            id<MTLBuffer> view =
                [_device newBufferWithBytesNoCopy:(void *)(uintptr_t)base
                                           length:(NSUInteger)(end - base)
                                          options:MTLResourceStorageModeShared
                                      deallocator:nil];
            if (!view)
                return blit_error(error,
                                  @"Cannot create shared blit alias view");
            read_buffer = write_buffer = view;
        }
        if (sa - base > UINT32_MAX - l.source_length ||
            da - base > UINT32_MAX - l.destination_length)
            return blit_error(error,
                              @"Shared blit alias offsets exceed native range");
        read_offset = (unsigned)(sa - base);
        write_offset = (unsigned)(da - base);
    }
    uint64_t blend_row = (uint64_t)c->row_bytes / l.bytes_per_pixel * 4;
    BOOL serial = alias || (c->operation == NV09F_SET_OPERATION_BLEND_AND &&
                            c->rows > 1 && blend_row > c->destination_pitch);
    NV2AMetalBlitUniforms u = { sa,
                                da,
                                read_offset,
                                write_offset,
                                c->source_pitch,
                                c->destination_pitch,
                                c->row_bytes,
                                c->rows,
                                c->tail_bytes,
                                c->operation,
                                c->beta >> 16,
                                l.bytes_per_pixel,
                                l.patch_alpha,
                                l.alpha_value };
    NSUInteger uniformOffset = 0;
    id<MTLBuffer> constants = [commands uploadBytes:&u
                                             length:sizeof(u)
                                             offset:&uniformOffset
                                              error:error];
    if (!constants)
        return NO;
    if (![commands addResource:source error:error] ||
        ![commands addResource:dest error:error] ||
        ![commands addResource:read_buffer error:error] ||
        ![commands addResource:write_buffer error:error] ||
        ![commands keepAlive:self error:error])
        return NO;
    [_arguments setAddress:read_buffer.gpuAddress atIndex:0];
    [_arguments setAddress:write_buffer.gpuAddress atIndex:1];
    [_arguments setAddress:constants.gpuAddress + uniformOffset atIndex:2];
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    if (!e)
        return blit_error(error, @"Cannot create native blit encoder");
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setArgumentTable:_arguments];
    [e setComputePipelineState:serial ? _serial : _parallel];
    unsigned count = MAX(c->rows ? c->row_bytes : 0, c->tail_bytes);
    if (c->operation == NV09F_SET_OPERATION_BLEND_AND)
        count = count / l.bytes_per_pixel * 3;
    NSUInteger rows = (NSUInteger)c->rows + (c->tail_bytes != 0);
    if (serial) {
        [e dispatchThreadgroups:MTLSizeMake(1, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(
                                      MIN(128u,
                                          _serial
                                              .maxTotalThreadsPerThreadgroup),
                                      1, 1)];
    } else if (count) {
        [e dispatchThreads:MTLSizeMake(count, rows, 1)
            threadsPerThreadgroup:MTLSizeMake(_parallel.threadExecutionWidth, 1,
                                              1)];
    }
    if (l.patch_alpha && MAX(c->rows ? c->row_bytes : 0, c->tail_bytes) / 4) {
        [e barrierAfterEncoderStages:MTLStageDispatch
                 beforeEncoderStages:MTLStageDispatch
                   visibilityOptions:MTL4VisibilityOptionDevice];
        [e setComputePipelineState:_alpha];
        [e dispatchThreads:MTLSizeMake(
                               MAX(c->rows ? c->row_bytes : 0, c->tail_bytes) /
                                   4,
                               rows, 1)
            threadsPerThreadgroup:MTLSizeMake(_alpha.threadExecutionWidth, 1,
                                              1)];
    }
    [e barrierAfterStages:MTLStageDispatch
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return YES;
}
@end
