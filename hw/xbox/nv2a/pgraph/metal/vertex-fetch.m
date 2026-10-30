/* SPDX-License-Identifier: LGPL-2.0-or-later */

#import "vertex-fetch.h"
#include "vertex-fetch-source.h"
#include <stdint.h>
#include <string.h>

_Static_assert(sizeof(NV2AMetalFetchUniforms) == 532, "CPU/MSL fetch layout");
_Static_assert(offsetof(NV2AMetalFetchUniforms, first_decoded_vertex) == 528,
               "CPU/MSL compact fetch offset");
_Static_assert(sizeof(NV2AMetalProgramInput) == 256,
               "CPU/MSL attribute layout");

static BOOL fetch_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.vertex-fetch"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

unsigned nv2a_metal_attribute_size(unsigned format, unsigned count)
{
    if (!count || count > 4) {
        return 0;
    }
    switch (format) {
    case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D:
        return count == 4 ? 4 : 0;
    case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL:
        return count;
    case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1:
    case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K:
        return 2 * count;
    case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F:
        return 4 * count;
    case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP:
        return count == 1 ? 4 : 0;
    default:
        return 0;
    }
}

@implementation NV2AMetalFetchResult
- (instancetype)initWithAttributes:(id<MTLBuffer>)attributes
                            faults:(id<MTLBuffer>)faults
                             count:(NSUInteger)count
                           current:(BOOL)current
{
    self = [super init];
    if (self) {
        _attributes = attributes;
        _faults = faults;
        _vertexCount = count;
        _hasCurrent = current;
        _faultSummaryOffset = (count + current) * sizeof(uint32_t);
    }
    return self;
}
@end

@implementation NV2AMetalVertexFetch {
    id<MTLDevice> _device;
    id<MTLComputePipelineState> _pipeline;
    id<MTL4ArgumentTable> _arguments;
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
        fetch_error(error, @"Metal 4 attribute fetch requires Apple Silicon");
        return nil;
    }
    _device = device;
    id<MTL4Compiler> compiler =
        [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                    error:error];
    if (!compiler) {
        return nil;
    }
    MTL4LibraryDescriptor *libraryDescriptor = [MTL4LibraryDescriptor new];
    libraryDescriptor.source = @(metal_shader_source);
    libraryDescriptor.options = [MTLCompileOptions new];
    libraryDescriptor.options.languageVersion = MTLLanguageVersion4_0;
    libraryDescriptor.options.mathMode = MTLMathModeSafe;
    libraryDescriptor.options.mathFloatingPointFunctions =
        MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> library =
        [compiler newLibraryWithDescriptor:libraryDescriptor error:error];
    if (!library) {
        return nil;
    }
    MTL4LibraryFunctionDescriptor *function =
        [MTL4LibraryFunctionDescriptor new];
    function.library = library;
    function.name = @"nv2a_vertex_fetch";
    MTL4ComputePipelineDescriptor *descriptor =
        [MTL4ComputePipelineDescriptor new];
    descriptor.computeFunctionDescriptor = function;
    _pipeline = [compiler newComputePipelineStateWithDescriptor:descriptor
                                            compilerTaskOptions:nil
                                                          error:error];
    if (!_pipeline) {
        return nil;
    }
    MTL4ArgumentTableDescriptor *arguments = [MTL4ArgumentTableDescriptor new];
    arguments.maxBufferBindCount = 21;
    arguments.initializeBindings = YES;
    _arguments = [device newArgumentTableWithDescriptor:arguments error:error];
    return _arguments ? self : nil;
}

- (nullable NV2AMetalFetchResult *)encodeSources:
                                       (const NV2AMetalAttributeSource *)sources
                                           count:(NSUInteger)count
                                     firstVertex:(unsigned int)firstVertex
                                         indices:(nullable id<MTLBuffer>)indices
                                     indexOffset:(NSUInteger)indexOffset
                                       indexSize:(unsigned int)indexSize
                                        commands:(NV2AMetalCommands *)commands
                                           error:(NSError **)error
{
    return [self encodeSources:sources
                         count:count
                   firstVertex:firstVertex
                       indices:indices
                   indexOffset:indexOffset
                     indexSize:indexSize
                 currentVertex:NSNotFound
                      commands:commands
                         error:error];
}

- (nullable NV2AMetalFetchResult *)encodeSources:
                                       (const NV2AMetalAttributeSource *)sources
                                           count:(NSUInteger)count
                                     firstVertex:(unsigned int)firstVertex
                                         indices:(nullable id<MTLBuffer>)indices
                                     indexOffset:(NSUInteger)indexOffset
                                       indexSize:(unsigned int)indexSize
                                   currentVertex:(NSUInteger)currentVertex
                                        commands:(NV2AMetalCommands *)commands
                                           error:(NSError **)error
{
    return [self encodeSources:sources
                         count:count
                   firstVertex:firstVertex
                       indices:indices
                   indexOffset:indexOffset
                     indexSize:indexSize
                 currentVertex:currentVertex
                skippingPrefix:0
                      commands:commands
                         error:error];
}

- (nullable NV2AMetalFetchResult *)encodeSources:
                                       (const NV2AMetalAttributeSource *)sources
                                           count:(NSUInteger)count
                                     firstVertex:(unsigned int)firstVertex
                                         indices:(nullable id<MTLBuffer>)indices
                                     indexOffset:(NSUInteger)indexOffset
                                       indexSize:(unsigned int)indexSize
                                   currentVertex:(NSUInteger)currentVertex
                                  skippingPrefix:(NSUInteger)prefix
                                        commands:(NV2AMetalCommands *)commands
                                           error:(NSError **)error
{
    if (!sources || !commands.commandBuffer || commands.device != _device ||
        count > UINT32_MAX || prefix > count ||
        (currentVertex != NSNotFound && currentVertex >= count) ||
        count - prefix + (currentVertex != NSNotFound) >
            _device.maxBufferLength / sizeof(NV2AMetalProgramInput) ||
        (!indices && (indexSize || indexOffset)) ||
        (indices &&
         (indices.device != _device || (indexSize != 2 && indexSize != 4) ||
          indexOffset > indices.length ||
          count > (indices.length - indexOffset) / indexSize)) ||
        (!indices && count && count - 1 > UINT32_MAX - firstVertex)) {
        fetch_error(error, @"Invalid Metal attribute fetch input or recording");
        return nil;
    }
    NV2AMetalFetchUniforms u = { 0 };
    u.vertex_count = (unsigned)count;
    u.first_vertex = firstVertex;
    u.index_size = indexSize;
    u.current_vertex =
        currentVertex == NSNotFound ? UINT32_MAX : (unsigned)currentVertex;
    u.first_decoded_vertex = (unsigned)prefix;
    NSUInteger decoded = count - prefix;
    NSUInteger records = decoded + (currentVertex != NSNotFound);
    NSUInteger work =
        decoded + (currentVertex != NSNotFound && currentVertex < prefix);
    for (unsigned i = 0; i < 16; i++) {
        const NV2AMetalAttributeSource *s = &sources[i];
        NV2AMetalFetchAttribute *a = &u.attributes[i];
        memcpy(a->inline_value, s->inline_value, sizeof(a->inline_value));
        if (!s->count) {
            continue;
        }
        unsigned size = nv2a_metal_attribute_size(s->format, s->count);
        if (!size || !s->buffer || s->buffer.device != _device ||
            s->offset > s->buffer.length ||
            size > s->buffer.length - s->offset) {
            fetch_error(error,
                        @"Invalid Metal attribute format or source span");
            return nil;
        }
        NSUInteger span =
            s->byteLength ? s->byteLength : s->buffer.length - s->offset;
        if (span > s->buffer.length - s->offset || size > span) {
            fetch_error(error, @"Metal attribute DMA span exceeds its buffer");
            return nil;
        }
        a->count = s->count;
        a->format = s->format;
        a->stride = s->stride;
        NSUInteger maxIndex =
            s->stride ? (span - size) / s->stride : UINT32_MAX;
        a->max_index = maxIndex > UINT32_MAX ? UINT32_MAX : (unsigned)maxIndex;
        if (!indices && count && s->stride &&
            firstVertex + count - 1 > a->max_index) {
            fetch_error(error,
                        @"Metal attribute fetch exceeds the source buffer");
            return nil;
        }
    }
    if (!records) {
        return [[NV2AMetalFetchResult alloc] initWithAttributes:nil
                                                         faults:nil
                                                          count:0
                                                        current:NO];
    }
    NSUInteger constantsOffset = 0;
    id<MTLBuffer> constants = [commands uploadBytes:&u
                                             length:sizeof(u)
                                             offset:&constantsOffset
                                              error:error];
    if (!constants) {
        return nil;
    }
    id<MTLBuffer> attributes =
        [_device newBufferWithLength:records * sizeof(NV2AMetalProgramInput)
                             options:MTLResourceStorageModeShared];
    id<MTLBuffer> faults =
        [_device newBufferWithLength:(records + 1) * sizeof(unsigned)
                             options:MTLResourceStorageModeShared];
    if (!attributes || !faults) {
        fetch_error(error, @"Could not allocate Metal attribute buffers");
        return nil;
    }
    uint32_t zero = 0;
    memcpy((uint8_t *)faults.contents + records * sizeof(uint32_t), &zero,
           sizeof(zero));
    if (![commands addResource:attributes error:error] ||
        ![commands addResource:faults error:error] ||
        ![commands keepAlive:self error:error] ||
        (indices && ![commands addResource:indices error:error])) {
        return nil;
    }
    for (unsigned i = 0; i < 16; i++) {
        const NV2AMetalAttributeSource *s = &sources[i];
        if (s->count && ![commands addResource:s->buffer error:error]) {
            return nil;
        }
        [_arguments setAddress:s->count ? s->buffer.gpuAddress + s->offset :
                                          constants.gpuAddress + constantsOffset
                       atIndex:i];
    }
    [_arguments setAddress:attributes.gpuAddress atIndex:16];
    [_arguments setAddress:faults.gpuAddress atIndex:17];
    [_arguments setAddress:constants.gpuAddress + constantsOffset atIndex:18];
    [_arguments setAddress:indices ? indices.gpuAddress + indexOffset :
                                     constants.gpuAddress + constantsOffset
                   atIndex:19];
    [_arguments setAddress:faults.gpuAddress + records * sizeof(uint32_t)
                   atIndex:20];
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        fetch_error(error, @"Could not create Metal attribute encoder");
        return nil;
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageDispatch
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder setArgumentTable:_arguments];
    [encoder setComputePipelineState:_pipeline];
    NSUInteger width = _pipeline.threadExecutionWidth;
    if (width > work) {
        width = work;
    }
    [encoder dispatchThreads:MTLSizeMake(work, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
    [encoder barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return [[NV2AMetalFetchResult alloc] initWithAttributes:attributes
                                                     faults:faults
                                                      count:decoded
                                                    current:currentVertex != NSNotFound];
}
@end
