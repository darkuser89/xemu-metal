/* Native pending transport. SPDX-License-Identifier: GPL-2.0-only OR
 * GPL-3.0-only */
#import "archive-native.h"
#include <stdint.h>
@implementation NV2AMetalDiscardedVertices
- (instancetype)initWithCount:(NSUInteger)count
{
    self = [super init];
    if (!self || !count || count > UINT32_MAX ||
        count > NSUIntegerMax / sizeof(NV2AMetalVertex))
        return nil;
    _count = count;
    return self;
}
@end
static BOOL native_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.pending-archive-native"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}
NV2AMetalPendingArchive *
nv2a_metal_pending_capture(NV2AMetalPendingJournal *journal,
                           NV2AMetalCommands *commands, NSError **error)
{
    if (!journal || !commands || commands.commandBuffer ||
        journal.streamCount > 1250) {
        native_error(error, @"Invalid pending native capture state");
        return nil;
    }
    NSArray *inputs = journal.retainedInputs,
            *retained = journal.retainedStreams;
    NSMutableArray *streams = [NSMutableArray new];
    NSUInteger total = 0;
    for (NSUInteger i = 0; i < inputs.count; i++) {
        NV2AMetalPendingInput *input = inputs[i];
        if (input.count > 524287 - total) {
            native_error(error, @"Pending capture exceeds aggregate limit");
            return nil;
        }
        total += input.count;
        NV2AMetalVertexStream *stream =
            [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                    limit:524287
                                                    error:error];
        if (!stream)
            return nil;
        for (NV2AMetalPendingSpan *span in retained[i]) {
            if ([span.resource
                    isMemberOfClass:NV2AMetalDiscardedVertices.class]) {
                NV2AMetalDiscardedVertices *zero = span.resource;
                if (span.first > zero.count ||
                    span.count > zero.count - span.first ||
                    ![stream appendDiscardedVertices:span.count error:error]) {
                    native_error(error, @"Invalid discarded vertex span");
                    return nil;
                }
                continue;
            }
            if (![span.resource conformsToProtocol:@protocol(MTLBuffer)] ||
                ![stream appendVertices:(id<MTLBuffer>)span.resource
                                  first:span.first
                                  count:span.count
                                  error:error]) {
                native_error(error, @"Invalid retained native vertex resource");
                return nil;
            }
        }
        if (stream.vertexCount != input.count) {
            native_error(error, @"Retained native vertex count mismatch");
            return nil;
        }
        [streams addObject:stream];
    }
    NSMutableArray *buffers = [NSMutableArray new],
                   *bytes = [NSMutableArray new];
    if (streams.count) {
        if (![commands beginWithError:error])
            return nil;
        for (NV2AMetalVertexStream *stream in streams) {
            id<MTLBuffer> buffer = [stream encodeWithCommands:commands
                                                        error:error];
            if (!buffer) {
                [commands cancel];
                return nil;
            }
            [buffers addObject:buffer];
        }
        if (![commands submitWithError:error]) {
            [commands cancel];
            return nil;
        }
        if (![commands waitUntilIdleWithError:error])
            return nil;
        for (id<MTLBuffer> buffer in buffers)
            [bytes addObject:[NSData dataWithBytes:buffer.contents
                                            length:buffer.length]];
    }
    return [[NV2AMetalPendingArchive alloc] initWithInputs:inputs
                                                  vertices:bytes
                                                     limit:524287
                                                     error:error];
}
static NV2AMetalPendingJournal *
pending_restore(NV2AMetalPendingArchive *archive, NV2AMetalCommands *commands,
                NSUInteger limit, BOOL raw, NSError **error)
{
    if (!archive || !commands || commands.commandBuffer || !limit) {
        native_error(error, @"Invalid pending native restore state");
        return nil;
    }
    NV2AMetalPendingJournal *journal =
        [[NV2AMetalPendingJournal alloc] initWithLimit:limit];
    NV2AMetalPendingPlan *plan = [journal planInputs:archive.inputs
                                 preservingLastArray:NO
                                               error:error];
    if (!plan)
        return nil;
    NSMutableArray *uploads = [NSMutableArray new],
                   *targets = [NSMutableArray new],
                   *spans = [NSMutableArray new];
    for (NSUInteger i = 0; i < archive.inputs.count; i++) {
        NSData *bytes = archive.vertices[i];
        if (!bytes.length || bytes.length > commands.device.maxBufferLength) {
            native_error(error, @"Pending restore buffer exceeds native limit");
            return nil;
        }
        BOOL zero = raw;
        const uint8_t *payload = bytes.bytes;
        for (NSUInteger n = 0; zero && n < bytes.length; n++)
            zero = payload[n] == 0;
        if (zero) {
            NV2AMetalDiscardedVertices *discarded =
                [[NV2AMetalDiscardedVertices alloc]
                    initWithCount:archive.inputs[i].count];
            NV2AMetalPendingSpan *span =
                discarded ?
                    [NV2AMetalPendingSpan resource:discarded
                                             first:0
                                             count:archive.inputs[i].count] :
                    nil;
            if (!span) {
                native_error(error, @"Invalid discarded restore span");
                return nil;
            }
            [spans addObject:span];
            continue;
        }
        id<MTLBuffer> upload =
            [commands.device newBufferWithBytes:bytes.bytes
                                         length:bytes.length
                                        options:MTLResourceStorageModeShared];
        id<MTLBuffer> gpu =
            [commands.device newBufferWithLength:bytes.length
                                         options:MTLResourceStorageModePrivate];
        if (!upload || !gpu) {
            native_error(error, @"Cannot allocate pending restore buffers");
            return nil;
        }
        [uploads addObject:upload];
        [targets addObject:gpu];
        [spans
            addObject:[NV2AMetalPendingSpan resource:gpu
                                               first:0
                                               count:archive.inputs[i].count]];
    }
    NV2AMetalPendingUpdate *update = [journal preparePlan:plan
                                                 suffixes:spans
                                                    error:error];
    if (!update)
        return nil;
    if (uploads.count) {
        if (![commands beginWithError:error])
            return nil;
        for (NSUInteger i = 0; i < uploads.count; i++)
            if (![commands addResource:uploads[i] error:error] ||
                ![commands addResource:targets[i] error:error]) {
                [commands cancel];
                return nil;
            }
        id<MTL4ComputeCommandEncoder> encoder =
            [commands.commandBuffer computeCommandEncoder];
        if (!encoder) {
            native_error(error, @"Cannot encode pending restore upload");
            [commands cancel];
            return nil;
        }
        for (NSUInteger i = 0; i < uploads.count; i++)
            [encoder copyFromBuffer:uploads[i]
                       sourceOffset:0
                           toBuffer:targets[i]
                  destinationOffset:0
                               size:((id<MTLBuffer>)uploads[i]).length];
        [encoder barrierAfterStages:MTLStageBlit
                  beforeQueueStages:MTLStageAll
                  visibilityOptions:MTL4VisibilityOptionDevice];
        [encoder endEncoding];
        if (![commands submitWithError:error]) {
            [commands cancel];
            return nil;
        }
        if (![commands waitUntilIdleWithError:error])
            return nil;
    }
    return [journal commitUpdate:update error:error] ? journal : nil;
}
NV2AMetalPendingJournal *
nv2a_metal_pending_restore(NV2AMetalPendingArchive *archive,
                           NV2AMetalCommands *commands, NSUInteger limit,
                           NSError **error)
{
    return pending_restore(archive, commands, limit, NO, error);
}
NV2AMetalPendingJournal *
nv2a_metal_pending_restore_raw(NV2AMetalPendingArchive *archive,
                               NV2AMetalCommands *commands, NSUInteger limit,
                               NSError **error)
{
    return pending_restore(archive, commands, limit, YES, error);
}
