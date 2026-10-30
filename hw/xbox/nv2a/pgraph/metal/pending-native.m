/* Native stream adapter. SPDX-License-Identifier: GPL-2.0-only OR
 * GPL-3.0-only */
#import "pending-native.h"
static BOOL native_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.pending-native"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}
@implementation NV2AMetalPendingNative {
    id<MTLDevice> _device;
    NSArray<NV2AMetalVertexStream *> *_streams;
}
- (instancetype)initWithUpdate:(NV2AMetalPendingUpdate *)update
                        device:(id<MTLDevice>)device
                         limit:(NSUInteger)limit
                         error:(NSError **)error
{
    return [self initWithUpdate:update
                         device:device
                    streamLimit:limit
                     totalLimit:limit
                          error:error];
}
- (instancetype)initWithUpdate:(NV2AMetalPendingUpdate *)update
                        device:(id<MTLDevice>)device
                   streamLimit:(NSUInteger)streamLimit
                    totalLimit:(NSUInteger)totalLimit
                         error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    if (!update || !device || !streamLimit || !totalLimit) {
        native_error(error, @"Invalid native pending update/device/limit");
        return nil;
    }
    NSMutableArray *streams = [NSMutableArray new],
                   *counts = [NSMutableArray new];
    NSUInteger total = 0;
    for (NSArray<NV2AMetalPendingSpan *> *spans in update.streams) {
        NV2AMetalVertexStream *stream =
            [[NV2AMetalVertexStream alloc] initWithDevice:device
                                                    limit:streamLimit
                                                    error:error];
        if (!stream)
            return nil;
        for (NV2AMetalPendingSpan *span in spans) {
            if (![span.resource conformsToProtocol:@protocol(MTLBuffer)] ||
                span.count > totalLimit - total) {
                native_error(
                    error,
                    @"Invalid native pending resource or aggregate count");
                return nil;
            }
            if (![stream appendVertices:(id<MTLBuffer>)span.resource
                                  first:span.first
                                  count:span.count
                                  error:error])
                return nil;
            total += span.count;
        }
        if (!stream.vertexCount) {
            native_error(error, @"Empty native pending stream");
            return nil;
        }
        [streams addObject:stream];
        [counts addObject:@(stream.vertexCount)];
    }
    _device = device;
    _streams = [streams copy];
    _counts = [counts copy];
    return self;
}
- (NSArray<id<MTLBuffer>> *)encodeWithCommands:(NV2AMetalCommands *)commands
                                         error:(NSError **)error
{
    if (!commands.commandBuffer || commands.device != _device) {
        native_error(
            error, @"Native pending streams require their device's recording");
        return nil;
    }
    NSMutableArray *buffers = [NSMutableArray new];
    for (NV2AMetalVertexStream *stream in _streams) {
        id<MTLBuffer> buffer = [stream encodeForDrawingWithCommands:commands
                                                            error:error];
        if (!buffer)
            return nil;
        [buffers addObject:buffer];
    }
    return [buffers copy];
}
- (NSArray<NV2AMetalVertexSlice *> *)
    encodeSlicesWithCommands:(NV2AMetalCommands *)commands
                       error:(NSError **)error
{
    if (!commands.commandBuffer || commands.device != _device) {
        native_error(error,
                     @"Native pending streams require their device's recording");
        return nil;
    }
    NSMutableArray *slices = [NSMutableArray new];
    for (NV2AMetalVertexStream *stream in _streams) {
        NV2AMetalVertexSlice *slice =
            [stream encodeSliceForDrawingWithCommands:commands error:error];
        if (!slice)
            return nil;
        [slices addObject:slice];
    }
    return [slices copy];
}
@end
