/* Native Metal4 vertex-stream assembly.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "vertex-stream.h"
#import "shader-library.h"
#include "geometry-source.h"
#include <stdint.h>

static BOOL stream_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.vertex-stream"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}

@implementation NV2AMetalIndexedVertices
- (instancetype)initWithVertices:(id<MTLBuffer>)vertices
                   physicalCount:(NSUInteger)physicalCount
                           remap:(NSData *)remap
                           error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    NSUInteger stride = sizeof(NV2AMetalVertex);
    if (!vertices || !physicalCount || physicalCount > UINT32_MAX ||
        physicalCount > vertices.length / stride ||
        physicalCount > vertices.device.maxBufferLength / stride ||
        !remap.length || remap.length % sizeof(uint32_t) ||
        remap.length / sizeof(uint32_t) > UINT32_MAX ||
        remap.length > vertices.device.maxBufferLength) {
        stream_error(error, @"Invalid indexed native vertex buffer or remap");
        return nil;
    }
    NSData *immutable = [remap copy];
    const uint32_t *map = immutable.bytes;
    NSUInteger count = immutable.length / sizeof(*map);
    for (NSUInteger i = 0; i < count; i++) {
        if (map[i] >= physicalCount) {
            stream_error(error,
                         @"Indexed native vertex remap exceeds physical range");
            return nil;
        }
    }
    id<MTLBuffer> indices =
        [vertices.device newBufferWithBytes:immutable.bytes
                                     length:immutable.length
                                    options:MTLResourceStorageModeShared];
    if (!indices) {
        stream_error(error, @"Cannot allocate immutable native vertex remap");
        return nil;
    }
    _vertices = vertices;
    _indices = indices;
    _remap = immutable;
    _physicalVertexCount = physicalCount;
    _vertexCount = count;
    return self;
}
@end

@interface NV2AMetalVertexSegment : NSObject
@property(nonatomic) id<MTLBuffer> buffer;
@property(nonatomic, nullable) NV2AMetalIndexedVertices *indexed;
@property(nonatomic) NSUInteger first, count, destination;
@end
@implementation NV2AMetalVertexSegment
@end

@interface NV2AMetalVertexCompactPlan : NSObject
@property(nonatomic) NSData *remap;
@property(nonatomic) NSArray<NV2AMetalVertexSegment *> *copies;
@property(nonatomic) NSUInteger physicalCount;
@end
@implementation NV2AMetalVertexCompactPlan
@end

@interface NV2AMetalVertexSlice ()
- (instancetype)initWithBuffer:(id<MTLBuffer>)buffer
                       indexed:(nullable NV2AMetalIndexedVertices *)indexed
                         first:(NSUInteger)first
                         count:(NSUInteger)count;
@end
@implementation NV2AMetalVertexSlice
- (instancetype)initWithBuffer:(id<MTLBuffer>)buffer
                       indexed:(NV2AMetalIndexedVertices *)indexed
                         first:(NSUInteger)first
                         count:(NSUInteger)count
{
    self = [super init];
    if (self) {
        _buffer = buffer;
        _indexedVertices = indexed;
        _firstVertex = first;
        _vertexCount = count;
    }
    return self;
}
@end

@implementation NV2AMetalVertexStream {
    id<MTLDevice> _device;
    NSUInteger _limit;
    NSMutableArray<NV2AMetalVertexSegment *> *_segments;
    BOOL _discarded, _indexed;
    NV2AMetalShaderLibrary *_module;
    id<MTLComputePipelineState> _gather;
    id<MTL4ArgumentTable> _arguments;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device
                         limit:(NSUInteger)limit
                         error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    if (!device || ![device supportsFamily:MTLGPUFamilyApple7] || !limit ||
        limit > UINT32_MAX ||
        limit > device.maxBufferLength / sizeof(NV2AMetalVertex)) {
        stream_error(error, @"Invalid native vertex stream device or limit");
        return nil;
    }
    _device = device;
    _limit = limit;
    _segments = [NSMutableArray new];
    return self;
}
- (BOOL)appendVertices:(id<MTLBuffer>)vertices
                 first:(NSUInteger)first
                 count:(NSUInteger)count
                 error:(NSError **)error
{
    NSUInteger stride = sizeof(NV2AMetalVertex);
    if (!count && !vertices && !first)
        return YES;
    if (!vertices || vertices.device != _device ||
        first > vertices.length / stride ||
        count > vertices.length / stride - first ||
        count > _limit - _vertexCount) {
        return stream_error(error,
                            @"Vertex stream segment exceeds buffer or limit");
    }
    if (!count)
        return YES;
    NV2AMetalVertexSegment *last = _segments.lastObject;
    if (!last.indexed && last.buffer == vertices &&
        last.first + last.count == first) {
        last.count += count;
        _vertexCount += count;
        return YES;
    }
    NV2AMetalVertexSegment *segment = [NV2AMetalVertexSegment new];
    segment.buffer = vertices;
    segment.first = first;
    segment.count = count;
    [_segments addObject:segment];
    _vertexCount += count;
    return YES;
}
- (BOOL)appendIndexedVertices:(NV2AMetalIndexedVertices *)vertices
                        first:(NSUInteger)first
                        count:(NSUInteger)count
                        error:(NSError **)error
{
    if (!vertices || vertices.vertices.device != _device ||
        first > vertices.vertexCount || count > vertices.vertexCount - first ||
        count > _limit - _vertexCount)
        return stream_error(
            error, @"Indexed vertex stream segment exceeds remap or limit");
    if (!count)
        return YES;
    NV2AMetalVertexSegment *last = _segments.lastObject;
    if (last.indexed == vertices && last.first + last.count == first) {
        last.count += count;
    } else {
        NV2AMetalVertexSegment *segment = [NV2AMetalVertexSegment new];
        segment.buffer = vertices.vertices;
        segment.indexed = vertices;
        segment.first = first;
        segment.count = count;
        [_segments addObject:segment];
    }
    _indexed = YES;
    _vertexCount += count;
    return YES;
}
- (BOOL)appendDiscardedVertices:(NSUInteger)count error:(NSError **)error
{
    if (count > _limit - _vertexCount)
        return stream_error(error, @"Discarded vertex segment exceeds limit");
    if (!count)
        return YES;
    NV2AMetalVertexSegment *last = _segments.lastObject;
    if (last && !last.buffer) {
        last.count += count;
    } else {
        NV2AMetalVertexSegment *segment = [NV2AMetalVertexSegment new];
        segment.count = count;
        [_segments addObject:segment];
    }
    _discarded = YES;
    _vertexCount += count;
    return YES;
}
- (NSData *)completedHostVertexData
{
    NSUInteger stride = sizeof(NV2AMetalVertex);
    for (NV2AMetalVertexSegment *segment in _segments) {
        if (segment.buffer &&
            segment.buffer.storageMode != MTLStorageModeShared)
            return nil;
    }
    NV2AMetalVertexSegment *only = _segments.firstObject;
    if (_segments.count == 1 && only.buffer && !only.indexed)
        return [NSData dataWithBytes:(const uint8_t *)only.buffer.contents +
                                     only.first * stride
                              length:_vertexCount * stride];
    NSMutableData *data = [NSMutableData dataWithLength:_vertexCount * stride];
    uint8_t *destination = data.mutableBytes;
    for (NV2AMetalVertexSegment *segment in _segments) {
        if (segment.indexed) {
            const uint32_t *map = segment.indexed.remap.bytes;
            const uint8_t *source = segment.buffer.contents;
            for (NSUInteger i = 0; i < segment.count; i++)
                memcpy(destination + i * stride,
                       source + map[segment.first + i] * stride, stride);
        } else if (segment.buffer) {
            memcpy(destination,
                   (const uint8_t *)segment.buffer.contents +
                       segment.first * stride,
                   segment.count * stride);
        }
        destination += segment.count * stride;
    }
    return data;
}
/* Prepare all indexed encoding state before obtaining a GPU encoder. */
- (BOOL)prepareGatherWithCommands:(NV2AMetalCommands *)commands
                            error:(NSError **)error
{
    if (!_module)
        _module = [NV2AMetalShaderLibrary sharedWithDevice:_device
                                                    source:metal_shader_source
                                                     error:error];
    if (!_module)
        return NO;
    if (!_gather)
        _gather = [_module computeFunction:@"nv2a_vertex_stream_gather"
                                     error:error];
    if (!_gather)
        return NO;
    if (!_arguments) {
        MTL4ArgumentTableDescriptor *descriptor =
            [MTL4ArgumentTableDescriptor new];
        descriptor.maxBufferBindCount = 4;
        descriptor.initializeBindings = YES;
        _arguments = [_device newArgumentTableWithDescriptor:descriptor
                                                       error:error];
    }
    return _arguments && [commands keepAlive:self error:error];
}
- (id<MTLBuffer>)encodeWithCommands:(NV2AMetalCommands *)commands
                              error:(NSError **)error
{
    return [self encodeWithCommands:commands reuseSource:NO error:error];
}
- (id<MTLBuffer>)encodeForDrawingWithCommands:(NV2AMetalCommands *)commands
                                        error:(NSError **)error
{
    return [self encodeWithCommands:commands reuseSource:YES error:error];
}
- (id<MTLBuffer>)encodeWithCommands:(NV2AMetalCommands *)commands
                        reuseSource:(BOOL)reuseSource
                              error:(NSError **)error
{
    if (!commands.commandBuffer || commands.device != _device) {
        stream_error(error, @"Vertex stream requires its device's recording");
        return nil;
    }
    if (!_vertexCount)
        return nil;
    if (reuseSource && _discarded) {
        stream_error(error, @"Discarded raster output cannot be drawn");
        return nil;
    }
    NV2AMetalVertexSegment *only = _segments.firstObject;
    if (reuseSource && _segments.count == 1 && !only.indexed && !only.first) {
        if (![commands addResource:only.buffer error:error])
            return nil;
        return only.buffer;
    }
    id<MTLBuffer> joined =
        [_device newBufferWithLength:_vertexCount * sizeof(NV2AMetalVertex)
                             options:MTLResourceStorageModeShared];
    if (!joined) {
        stream_error(error, @"Cannot allocate joined native vertex stream");
        return nil;
    }
    if (![commands addResource:joined error:error])
        return nil;
    for (NV2AMetalVertexSegment *segment in _segments)
        if (segment.buffer && ![commands addResource:segment.buffer
                                               error:error])
            return nil;
    /* uploadBytes retains each buffer in the recording. Keep only its GPU
     * address for the later encoder, instead of two temporary containers. */
    __attribute__((objc_precise_lifetime)) NSMutableData *countAddresses =
        _indexed ? [NSMutableData
                       dataWithLength:_segments.count * sizeof(MTLGPUAddress)] :
                   nil;
    MTLGPUAddress *countAddress = countAddresses.mutableBytes;
    if (_indexed) {
        if (!countAddress) {
            stream_error(error, @"Cannot allocate indexed vertex counts");
            return nil;
        }
        if (![self prepareGatherWithCommands:commands error:error])
            return nil;
        for (NSUInteger i = 0; i < _segments.count; i++) {
            NV2AMetalVertexSegment *segment = _segments[i];
            uint32_t count = (uint32_t)segment.count;
            NSUInteger offset = 0;
            id<MTLBuffer> constants = [commands uploadBytes:&count
                                                     length:sizeof(count)
                                                     offset:&offset
                                                      error:error];
            if (!constants ||
                (segment.indexed &&
                 (![commands addResource:segment.indexed.indices error:error] ||
                  ![commands keepAlive:segment.indexed error:error])))
                return nil;
            countAddress[i] = constants.gpuAddress + offset;
        }
    }
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        stream_error(error, @"Cannot encode native vertex stream copies");
        return nil;
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit | MTLStageDispatch
                   visibilityOptions:MTL4VisibilityOptionDevice];
    NSUInteger destination = 0;
    for (NSUInteger i = 0; i < _segments.count; i++) {
        NV2AMetalVertexSegment *segment = _segments[i];
        NSUInteger bytes = segment.count * sizeof(NV2AMetalVertex);
        if (segment.indexed) {
            [_arguments setAddress:segment.buffer.gpuAddress atIndex:0];
            [_arguments setAddress:segment.indexed.indices.gpuAddress +
                                   segment.first * sizeof(uint32_t)
                           atIndex:1];
            [_arguments setAddress:joined.gpuAddress + destination atIndex:2];
            [_arguments setAddress:countAddress[i] atIndex:3];
            [encoder setArgumentTable:_arguments];
            [encoder setComputePipelineState:_gather];
            [encoder dispatchThreads:MTLSizeMake(segment.count, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(
                                          MIN(segment.count,
                                              _gather.threadExecutionWidth),
                                          1, 1)];
        } else if (!segment.buffer) {
            [encoder fillBuffer:joined
                          range:NSMakeRange(destination, bytes)
                          value:0];
        } else {
            [encoder copyFromBuffer:segment.buffer
                       sourceOffset:segment.first * sizeof(NV2AMetalVertex)
                           toBuffer:joined
                  destinationOffset:destination
                               size:bytes];
        }
        destination += bytes;
    }
    [encoder barrierAfterStages:MTLStageBlit | MTLStageDispatch
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return joined;
}
/* Whole, distinct indexed owners need no per-record dictionaries or sorting
 * when every physical record is referenced. Bound the temporary raw payload;
 * optional metadata allocation failures leave the general planner available.
 */
- (NV2AMetalVertexCompactPlan *)densePlan
{
    enum { MaximumPayload = 64 * 1024 };
    NSUInteger sources = _segments.count;
    if (_discarded || !sources || !_vertexCount ||
        sources > MaximumPayload / (2 * sizeof(uintptr_t)))
        return nil;
    NSUInteger slots = 1;
    while (slots < 2 * sources) {
        if (slots > MaximumPayload / (2 * sizeof(uintptr_t)))
            return nil;
        slots *= 2;
    }
    NSUInteger tableBytes = slots * sizeof(uintptr_t);
    NSUInteger bitmapBytes = 0, physicalCount = 0, logicalCount = 0;
    for (NV2AMetalVertexSegment *segment in _segments) {
        NV2AMetalIndexedVertices *owner = segment.indexed;
        NSUInteger physical = owner.physicalVertexCount;
        if (!owner || segment.first || segment.buffer != owner.vertices ||
            segment.count != owner.vertexCount || !physical ||
            physical > segment.count ||
            physical > segment.buffer.length / sizeof(NV2AMetalVertex) ||
            segment.count > _vertexCount - logicalCount ||
            physical > _vertexCount - physicalCount ||
            owner.remap.length != segment.count * sizeof(uint32_t))
            return nil;
        logicalCount += segment.count;
        physicalCount += physical;
        bitmapBytes = MAX(bitmapBytes, (physical + 7) / 8);
    }
    if (logicalCount != _vertexCount || tableBytes > MaximumPayload ||
        bitmapBytes > MaximumPayload - tableBytes)
        return nil;
    __attribute__((objc_precise_lifetime)) NSMutableData *identities =
        [NSMutableData dataWithLength:tableBytes];
    if (identities.length != tableBytes)
        return nil;
    __attribute__((objc_precise_lifetime)) NSMutableData *bitmap =
        [NSMutableData dataWithLength:bitmapBytes];
    if (bitmap.length != bitmapBytes)
        return nil;
    uintptr_t *table = identities.mutableBytes;
    uint8_t *seen = bitmap.mutableBytes;
    if (!table || !seen)
        return nil;
    for (NV2AMetalVertexSegment *segment in _segments) {
        uintptr_t source = (uintptr_t)(__bridge void *)segment.buffer;
        uintptr_t hash = source >> 4;
        hash ^= hash >> 17;
        hash ^= hash >> 9;
        NSUInteger slot = hash & (slots - 1);
        BOOL inserted = NO;
        for (NSUInteger probe = 0; probe < slots; probe++) {
            if (table[slot] == source)
                return nil;
            if (!table[slot]) {
                table[slot] = source;
                inserted = YES;
                break;
            }
            slot = (slot + 1) & (slots - 1);
        }
        if (!inserted)
            return nil;
    }
    for (NV2AMetalVertexSegment *segment in _segments) {
        NSUInteger physical = segment.indexed.physicalVertexCount;
        memset(seen, 0, (physical + 7) / 8);
        const uint32_t *map = segment.indexed.remap.bytes;
        NSUInteger referenced = 0;
        for (NSUInteger i = 0; i < segment.count; i++) {
            uint32_t value = map[i];
            if (value >= physical)
                return nil;
            uint8_t bit = (uint8_t)(1u << (value & 7));
            if (!(seen[value >> 3] & bit)) {
                seen[value >> 3] |= bit;
                referenced++;
            }
        }
        if (referenced != physical)
            return nil;
    }
    NSMutableData *remap =
        [NSMutableData dataWithLength:_vertexCount * sizeof(uint32_t)];
    if (!remap)
        return nil;
    NSMutableArray<NV2AMetalVertexSegment *> *copies = [NSMutableArray new];
    if (!copies)
        return nil;
    NV2AMetalVertexCompactPlan *plan = [NV2AMetalVertexCompactPlan new];
    if (!plan)
        return nil;
    uint32_t *destination = remap.mutableBytes;
    if (!destination)
        return nil;
    NSUInteger logical = 0, base = 0;
    for (NV2AMetalVertexSegment *segment in _segments) {
        NV2AMetalVertexSegment *copy = [NV2AMetalVertexSegment new];
        if (!copy)
            return nil;
        copy.buffer = segment.buffer;
        copy.count = segment.indexed.physicalVertexCount;
        copy.destination = base;
        [copies addObject:copy];
        const uint32_t *map = segment.indexed.remap.bytes;
        for (NSUInteger i = 0; i < segment.count; i++)
            destination[logical++] = (uint32_t)(base + map[i]);
        base += copy.count;
    }
    plan.remap = remap;
    plan.copies = copies;
    plan.physicalCount = physicalCount;
    return plan;
}
/* Compact only referenced physical records, once per source buffer. Planning
 * uses logical metadata without inspecting the physical vertex bytes. */
- (NV2AMetalVertexCompactPlan *)compactPlan
{
    NV2AMetalVertexCompactPlan *dense = [self densePlan];
    if (dense)
        return dense;
    NSMapTable<id, NSMutableDictionary<NSNumber *, NSNumber *> *> *groups =
        [NSMapTable
            mapTableWithKeyOptions:NSPointerFunctionsStrongMemory |
                                   NSPointerFunctionsObjectPointerPersonality
                      valueOptions:NSPointerFunctionsStrongMemory];
    NSMutableArray *sources = [NSMutableArray new];
    for (NV2AMetalVertexSegment *segment in _segments) {
        id source = segment.buffer ?: (id)NSNull.null;
        NSMutableDictionary *references = [groups objectForKey:source];
        if (!references) {
            references = [NSMutableDictionary new];
            [groups setObject:references forKey:source];
            [sources addObject:source];
        }
        const uint32_t *map = segment.indexed.remap.bytes;
        for (NSUInteger i = 0; i < segment.count; i++) {
            NSUInteger physical = !segment.buffer ? 0 :
                                  map             ? map[segment.first + i] :
                                                    segment.first + i;
            references[@(physical)] = @0;
        }
    }
    NSUInteger physicalCount = 0;
    NSMutableArray<NV2AMetalVertexSegment *> *copies = [NSMutableArray new];
    for (id source in sources) {
        NSMutableDictionary<NSNumber *, NSNumber *> *references =
            [groups objectForKey:source];
        NSArray<NSNumber *> *ordered =
            [references.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSNumber *physical in ordered) {
            references[physical] = @(physicalCount);
            NV2AMetalVertexSegment *last = copies.lastObject;
            id<MTLBuffer> buffer = source == NSNull.null ? nil : source;
            if (last && last.buffer == buffer &&
                last.first + last.count == physical.unsignedIntegerValue) {
                last.count++;
            } else {
                NV2AMetalVertexSegment *copy = [NV2AMetalVertexSegment new];
                copy.buffer = buffer;
                copy.first = physical.unsignedIntegerValue;
                copy.destination = physicalCount;
                copy.count = 1;
                [copies addObject:copy];
            }
            physicalCount++;
        }
    }
    NSMutableData *remap =
        [NSMutableData dataWithLength:_vertexCount * sizeof(uint32_t)];
    uint32_t *destination = remap.mutableBytes;
    NSUInteger logical = 0;
    for (NV2AMetalVertexSegment *segment in _segments) {
        NSDictionary<NSNumber *, NSNumber *> *references =
            [groups objectForKey:segment.buffer ?: (id)NSNull.null];
        const uint32_t *map = segment.indexed.remap.bytes;
        for (NSUInteger i = 0; i < segment.count; i++) {
            NSUInteger physical = !segment.buffer ? 0 :
                                  map             ? map[segment.first + i] :
                                                    segment.first + i;
            destination[logical++] = references[@(physical)].unsignedIntValue;
        }
    }
    NV2AMetalVertexCompactPlan *plan = [NV2AMetalVertexCompactPlan new];
    plan.remap = remap;
    plan.copies = copies;
    plan.physicalCount = physicalCount;
    return plan;
}
- (NSData *)completedHostCompactVertexDataWithRemap:(NSData **)remap
{
    for (NV2AMetalVertexSegment *segment in _segments)
        if (segment.buffer &&
            segment.buffer.storageMode != MTLStorageModeShared)
            return nil;
    NV2AMetalVertexCompactPlan *plan = [self compactPlan];
    NSUInteger stride = sizeof(NV2AMetalVertex);
    NSMutableData *data =
        [NSMutableData dataWithLength:plan.physicalCount * stride];
    for (NV2AMetalVertexSegment *copy in plan.copies)
        if (copy.buffer)
            memcpy((uint8_t *)data.mutableBytes + copy.destination * stride,
                   (const uint8_t *)copy.buffer.contents + copy.first * stride,
                   copy.count * stride);
    if (remap)
        *remap = plan.remap;
    return data;
}
- (NV2AMetalVertexSlice *)
    encodeCompactSliceForCaptureWithCommands:(NV2AMetalCommands *)commands
                                       error:(NSError **)error
{
    if (!commands.commandBuffer || commands.device != _device) {
        stream_error(error, @"Vertex stream requires its device's recording");
        return nil;
    }
    return _vertexCount ?
               [self encodeCompactSliceWithCommands:commands error:error] :
               nil;
}
- (NV2AMetalVertexSlice *)encodeCompactSliceWithCommands:
                              (NV2AMetalCommands *)commands
                                                   error:(NSError **)error
{
    NV2AMetalVertexCompactPlan *plan = [self compactPlan];
    id<MTLBuffer> joined = [_device
        newBufferWithLength:plan.physicalCount * sizeof(NV2AMetalVertex)
                    options:MTLResourceStorageModeShared];
    NV2AMetalIndexedVertices *owner =
        joined ? [[NV2AMetalIndexedVertices alloc]
                     initWithVertices:joined
                        physicalCount:plan.physicalCount
                                remap:plan.remap
                                error:error] :
                 nil;
    if (!owner) {
        if (!joined)
            stream_error(error,
                         @"Cannot allocate compact native vertex stream");
        return nil;
    }
    if (![commands addResource:joined error:error] ||
        ![commands addResource:owner.indices error:error] ||
        ![commands keepAlive:owner error:error])
        return nil;
    for (NV2AMetalVertexSegment *copy in plan.copies)
        if (copy.buffer && ![commands addResource:copy.buffer error:error])
            return nil;
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        stream_error(error,
                     @"Cannot encode compact native vertex stream copies");
        return nil;
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    for (NV2AMetalVertexSegment *copy in plan.copies) {
        if (copy.buffer)
            [encoder copyFromBuffer:copy.buffer
                       sourceOffset:copy.first * sizeof(NV2AMetalVertex)
                           toBuffer:joined
                  destinationOffset:copy.destination * sizeof(NV2AMetalVertex)
                               size:copy.count * sizeof(NV2AMetalVertex)];
        else
            [encoder fillBuffer:joined
                          range:NSMakeRange(
                                    copy.destination * sizeof(NV2AMetalVertex),
                                    copy.count * sizeof(NV2AMetalVertex))
                          value:0];
    }
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return [[NV2AMetalVertexSlice alloc] initWithBuffer:joined
                                                indexed:owner
                                                  first:0
                                                  count:_vertexCount];
}
- (NV2AMetalVertexSlice *)encodeSliceForDrawingWithCommands:
                              (NV2AMetalCommands *)commands
                                                      error:(NSError **)error
{
    if (!commands.commandBuffer || commands.device != _device) {
        stream_error(error, @"Vertex stream requires its device's recording");
        return nil;
    }
    if (!_vertexCount)
        return nil;
    if (_discarded) {
        stream_error(error, @"Discarded raster output cannot be drawn");
        return nil;
    }
    NV2AMetalVertexSegment *only = _segments.firstObject;
    if (_segments.count == 1) {
        if (![commands addResource:only.buffer error:error] ||
            (only.indexed && (![commands addResource:only.indexed.indices
                                               error:error] ||
                              ![commands keepAlive:only.indexed error:error])))
            return nil;
        return [[NV2AMetalVertexSlice alloc] initWithBuffer:only.buffer
                                                    indexed:only.indexed
                                                      first:only.first
                                                      count:_vertexCount];
    }
    if (_indexed)
        return [self encodeCompactSliceWithCommands:commands error:error];
    id<MTLBuffer> joined = [self encodeWithCommands:commands error:error];
    return joined ? [[NV2AMetalVertexSlice alloc] initWithBuffer:joined
                                                         indexed:nil
                                                           first:0
                                                           count:_vertexCount] :
                    nil;
}
@end
