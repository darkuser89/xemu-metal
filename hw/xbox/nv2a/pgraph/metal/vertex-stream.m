/* Native Metal4 vertex-stream assembly.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "vertex-stream.h"

static BOOL stream_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.vertex-stream"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}

@interface NV2AMetalVertexSegment : NSObject
@property(nonatomic) id<MTLBuffer> buffer;
@property(nonatomic) NSUInteger offset, count;
@end
@implementation NV2AMetalVertexSegment
@end

@interface NV2AMetalVertexSlice ()
- (instancetype)initWithBuffer:(id<MTLBuffer>)buffer
                         first:(NSUInteger)first
                         count:(NSUInteger)count;
@end
@implementation NV2AMetalVertexSlice
- (instancetype)initWithBuffer:(id<MTLBuffer>)buffer
                         first:(NSUInteger)first
                         count:(NSUInteger)count
{
    self = [super init];
    if (self) {
        _buffer = buffer;
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
    BOOL _discarded;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device
                         limit:(NSUInteger)limit
                         error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    if (!device || ![device supportsFamily:MTLGPUFamilyApple7] || !limit ||
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
    if (last.buffer == vertices && last.offset / stride + last.count == first) {
        last.count += count;
        _vertexCount += count;
        return YES;
    }
    NV2AMetalVertexSegment *segment = [NV2AMetalVertexSegment new];
    segment.buffer = vertices;
    segment.offset = first * stride;
    segment.count = count;
    [_segments addObject:segment];
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
    if (reuseSource && _segments.count == 1 && !only.offset) {
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
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        stream_error(error, @"Cannot encode native vertex stream copies");
        return nil;
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    NSUInteger destination = 0;
    for (NV2AMetalVertexSegment *segment in _segments) {
        NSUInteger bytes = segment.count * sizeof(NV2AMetalVertex);
        if (!segment.buffer) {
            [encoder fillBuffer:joined
                          range:NSMakeRange(destination, bytes)
                          value:0];
        } else {
            [encoder copyFromBuffer:segment.buffer
                       sourceOffset:segment.offset
                           toBuffer:joined
                  destinationOffset:destination
                               size:bytes];
        }
        destination += bytes;
    }
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return joined;
}
- (NV2AMetalVertexSlice *)
    encodeSliceForDrawingWithCommands:(NV2AMetalCommands *)commands
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
        if (![commands addResource:only.buffer error:error])
            return nil;
        return [[NV2AMetalVertexSlice alloc]
            initWithBuffer:only.buffer
                     first:only.offset / sizeof(NV2AMetalVertex)
                     count:_vertexCount];
    }
    id<MTLBuffer> joined = [self encodeWithCommands:commands error:error];
    return joined ? [[NV2AMetalVertexSlice alloc] initWithBuffer:joined
                                                           first:0
                                                           count:_vertexCount] :
                    nil;
}
@end
