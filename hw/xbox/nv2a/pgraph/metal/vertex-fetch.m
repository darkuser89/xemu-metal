/* SPDX-License-Identifier: LGPL-2.0-or-later */

#import "vertex-fetch.h"
#import "shader-library.h"
#include "vertex-fetch-source.h"
#include <stdint.h>
#include <string.h>

_Static_assert(sizeof(NV2AMetalFetchUniforms) == 536, "CPU/MSL fetch layout");
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

@implementation NV2AMetalFetchResult {
    NV2AMetalFetchUniforms _sourceUniforms;
    BOOL _hasSourceUniforms;
    __weak NV2AMetalCommands *_owner;
    uint64_t _recordingSerial;
    NSData *_pgraphCurrent;
    uint16_t _constantAttributes;
    NSData *_floatProofSummaries;
    uint64_t _floatProofLanes;
    NSUInteger _floatProofFirst, _floatProofCount;
}
- (instancetype)initWithAttributes:(id<MTLBuffer>)attributes
                            faults:(id<MTLBuffer>)faults
                             count:(NSUInteger)count
                           current:(BOOL)current
                     summaryOffset:(NSUInteger)summaryOffset
                          uniforms:(const NV2AMetalFetchUniforms *)uniforms
                          commands:(NV2AMetalCommands *)commands
{
    self = [super init];
    if (self) {
        _attributes = attributes;
        _faults = faults;
        _vertexCount = count;
        _hasCurrent = current;
        _faultSummaryOffset = summaryOffset;
        if (attributes && uniforms) {
            _sourceUniforms = *uniforms;
            _hasSourceUniforms = YES;
            _owner = commands;
            _recordingSerial = commands.recordingSerial;
        }
    }
    return self;
}
- (BOOL)getSourceUniforms:(NV2AMetalFetchUniforms *)uniforms
          attributeBuffer:(id<MTLBuffer>)attributes
                    first:(NSUInteger)first
                    count:(NSUInteger)count
                 commands:(NV2AMetalCommands *)commands
{
    NSUInteger records = _vertexCount + _hasCurrent;
    if (!uniforms || !_hasSourceUniforms || !attributes ||
        attributes != _attributes || !commands || commands != _owner ||
        !commands.commandBuffer ||
        commands.recordingSerial != _recordingSerial || first > records ||
        count > records - first)
        return NO;
    *uniforms = _sourceUniforms;
    return YES;
}
/* Private producer handoff: only PGRAPH's guarded host capture calls this.
 * Generic buffer fetches cannot infer CPU values from GPU-owned storage. */
- (void)bindPGRAPHCurrentProof:(NSData *)current
                     commands:(NV2AMetalCommands *)commands
{
    if (_pgraphCurrent || current.length != sizeof(NV2AMetalProgramInput) ||
        [current isKindOfClass:NSMutableData.class])
        return;
    NV2AMetalFetchUniforms uniforms;
    if (![self getSourceUniforms:&uniforms attributeBuffer:_attributes
                            first:0 count:0 commands:commands] ||
        (uniforms.index_size && uniforms.first_vertex) ||
        (!uniforms.index_size && uniforms.vertex_count &&
         (uint64_t)uniforms.first_vertex + uniforms.vertex_count - 1 > UINT32_MAX))
        return;
    for (unsigned i = 0; i < NV2A_METAL_VP_ATTRIBUTES; i++) {
        const NV2AMetalFetchAttribute *a = &uniforms.attributes[i];
        if (nv2a_metal_attribute_size(a->format, a->count) && !a->stride &&
            a->max_index == UINT32_MAX)
            _constantAttributes |= 1u << i;
    }
    if (_constantAttributes)
        _pgraphCurrent = current;
}
- (BOOL)getReadonlyProofUniforms:(NV2AMetalFetchUniforms *)uniforms
                attributeBuffer:(id<MTLBuffer>)attributes
                          first:(NSUInteger)first
                          count:(NSUInteger)count
                       commands:(NV2AMetalCommands *)commands
{
    if (![self getSourceUniforms:uniforms attributeBuffer:attributes
                            first:first count:count commands:commands])
        return NO;
    const NV2AMetalProgramInput *current = _pgraphCurrent.bytes;
    unsigned constantAttributes = _constantAttributes;
    while (constantAttributes) {
        unsigned i = __builtin_ctz(constantAttributes);
        uniforms->attributes[i].count = 0;
        memcpy(uniforms->attributes[i].inline_value, current->attributes[i], 16);
        constantAttributes &= constantAttributes - 1;
    }
    return YES;
}
/* Only PGRAPH's guarded capture can attach host evidence. No guest pointer,
 * index view or source buffer is retained by this output metadata. */
- (void)bindPGRAPHFloatProofSummaries:(NSData *)summaries
                             laneMask:(uint64_t)laneMask
                                first:(NSUInteger)first
                                count:(NSUInteger)count
                             commands:(NV2AMetalCommands *)commands
{
    NV2AMetalFetchUniforms uniforms;
    if (_floatProofSummaries || !laneMask || !count ||
        summaries.length != 64 * sizeof(NV2AMetalFloatLaneSummary) ||
        [summaries isKindOfClass:NSMutableData.class] || first > _vertexCount ||
        count > _vertexCount - first ||
        ![self getSourceUniforms:&uniforms
                 attributeBuffer:_attributes
                           first:first
                           count:count
                        commands:commands] ||
        (uniforms.index_size && uniforms.first_vertex) ||
        (!uniforms.index_size && uniforms.vertex_count &&
         (uint64_t)uniforms.first_vertex + uniforms.vertex_count - 1 >
             UINT32_MAX))
        return;
    _floatProofSummaries = [summaries copy];
    _floatProofLanes = laneMask;
    _floatProofFirst = first;
    _floatProofCount = count;
}
- (BOOL)getFloatProofSummaries:(NSData **)summaries
                      laneMask:(uint64_t *)laneMask
               attributeBuffer:(id<MTLBuffer>)attributes
                         first:(NSUInteger)first
                         count:(NSUInteger)count
                      commands:(NV2AMetalCommands *)commands
{
    if (summaries)
        *summaries = nil;
    if (laneMask)
        *laneMask = 0;
    NV2AMetalFetchUniforms uniforms;
    if (!_floatProofSummaries || first < _floatProofFirst ||
        first - _floatProofFirst > _floatProofCount ||
        count > _floatProofCount - (first - _floatProofFirst) ||
        ![self getSourceUniforms:&uniforms
                 attributeBuffer:attributes
                           first:first
                           count:count
                        commands:commands])
        return NO;
    if (summaries)
        *summaries = _floatProofSummaries;
    if (laneMask)
        *laneMask = _floatProofLanes;
    return YES;
}
@end

typedef struct NV2AMetalFetchUniformSlot {
    const uint8_t *bytes;
    MTLGPUAddress address;
} NV2AMetalFetchUniformSlot;

@implementation NV2AMetalVertexFetch {
    id<MTLDevice> _device;
    NV2AMetalShaderLibrary *_module;
    id<MTLComputePipelineState> _pipeline;
    id<MTL4ArgumentTable> _arguments;
    BOOL _faultSummaryOnly;
    __weak NV2AMetalCommands *_uniformCommands;
    uint64_t _uniformSerial;
    NV2AMetalFetchUniformSlot _uniformSlots[4];
    unsigned _uniformSlotCount, _nextUniformSlot;
}

- (MTLGPUAddress)addressForUniforms:(const NV2AMetalFetchUniforms *)uniforms
                           commands:(NV2AMetalCommands *)commands
                              error:(NSError **)error
{
    /* Upload slices stay immutable while this recording is live. Seal/cancel
     * ends its identity before the arena can be rewound or reused. */
    uint64_t serial = commands.recordingSerial;
    if (_uniformCommands != commands || _uniformSerial != serial) {
        _uniformCommands = commands;
        _uniformSerial = serial;
        _uniformSlotCount = _nextUniformSlot = 0;
    }
    for (unsigned i = 0; i < _uniformSlotCount; i++) {
        NV2AMetalFetchUniformSlot slot = _uniformSlots[i];
        if (!memcmp(slot.bytes, uniforms, sizeof(*uniforms)))
            return slot.address;
    }
    NSUInteger offset;
    id<MTLBuffer> buffer = [commands uploadBytes:uniforms
                                          length:sizeof(*uniforms)
                                          offset:&offset
                                           error:error];
    if (!buffer)
        return 0;
    MTLGPUAddress address = buffer.gpuAddress + offset;
    _uniformSlots[_nextUniformSlot] =
        (NV2AMetalFetchUniformSlot){ (const uint8_t *)buffer.contents + offset,
                                     address };
    unsigned capacity = sizeof(_uniformSlots) / sizeof(*_uniformSlots);
    _nextUniformSlot = (_nextUniformSlot + 1) % capacity;
    _uniformSlotCount = MIN(_uniformSlotCount + 1, capacity);
    return address;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError **)error
{
    return [self initWithDevice:device faultSummaryOnly:NO error:error];
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                        faultSummaryOnly:(BOOL)faultSummaryOnly
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
    _faultSummaryOnly = faultSummaryOnly;
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
    u.record_faults = !_faultSummaryOnly;
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
                                                        current:NO
                                                  summaryOffset:0
                                                       uniforms:&u
                                                       commands:commands];
    }
    if (!_pipeline) {
        _module = [NV2AMetalShaderLibrary sharedWithDevice:_device
                                                   source:metal_shader_source
                                                    error:error];
        if (!_module)
            return nil;
        _pipeline = [_module computeFunction:@"nv2a_vertex_fetch" error:error];
        if (!_pipeline)
            return nil;
    }
    MTLGPUAddress uniformAddress = [self addressForUniforms:&u
                                                  commands:commands
                                                     error:error];
    if (!uniformAddress) {
        return nil;
    }
    id<MTLBuffer> attributes =
        [_device newBufferWithLength:records * sizeof(NV2AMetalProgramInput)
                             options:MTLResourceStorageModeShared];
    NSUInteger summaryOffset = _faultSummaryOnly ? 0 : records * sizeof(uint32_t);
    id<MTLBuffer> faults =
        [_device newBufferWithLength:summaryOffset + sizeof(uint32_t)
                             options:MTLResourceStorageModeShared];
    if (!attributes || !faults) {
        fetch_error(error, @"Could not allocate Metal attribute buffers");
        return nil;
    }
    uint32_t zero = 0;
    memcpy((uint8_t *)faults.contents + summaryOffset, &zero,
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
                                          uniformAddress
                       atIndex:i];
    }
    [_arguments setAddress:attributes.gpuAddress atIndex:16];
    [_arguments setAddress:faults.gpuAddress atIndex:17];
    [_arguments setAddress:uniformAddress atIndex:18];
    [_arguments setAddress:indices ? indices.gpuAddress + indexOffset :
                                     uniformAddress
                   atIndex:19];
    [_arguments setAddress:faults.gpuAddress + summaryOffset
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
    return [[NV2AMetalFetchResult alloc]
        initWithAttributes:attributes
                    faults:faults
                     count:decoded
                   current:currentVertex != NSNotFound
             summaryOffset:summaryOffset
                  uniforms:&u
                  commands:commands];
}
@end
