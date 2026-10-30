/* Captured XF epoch executor. SPDX-License-Identifier: GPL-2.0-only OR
 * GPL-3.0-only */
#import "vertex-epoch.h"
#include <limits.h>
static BOOL epoch_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.epoch-executor"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}
@interface NV2AMetalEpochResult ()
- (instancetype)initRegisters:(nullable id<MTLBuffer>)registers
                     vertices:(nullable id<MTLBuffer>)vertices
                        count:(NSUInteger)count
                    constants:(NSData *)constants
                      written:(NSData *)written;
@end
@implementation NV2AMetalEpochResult
- (instancetype)initRegisters:(id<MTLBuffer>)registers
                     vertices:(id<MTLBuffer>)vertices
                        count:(NSUInteger)count
                    constants:(NSData *)constants
                      written:(NSData *)written
{
    self = [super init];
    if (self) {
        _registers = registers;
        _vertices = vertices;
        _vertexCount = count;
        _constants = [constants copy];
        _written = [written copy];
    }
    return self;
}
@end
@interface NV2AMetalEpochEncoding ()
@property(nonatomic, readonly, nullable)
    NV2AMetalWritableEncoding *programEncoding;
- (instancetype)initProgram:(NV2AMetalWritableEncoding *)program;
- (instancetype)initFixed:(NV2AMetalEpochResult *)fixed
                 commands:(NV2AMetalCommands *)commands;
@end
@implementation NV2AMetalEpochEncoding {
    NV2AMetalWritableEncoding *_program;
    NV2AMetalEpochResult *_fixed;
    __weak NV2AMetalCommands *_fixedCommands;
}
- (instancetype)initProgram:(NV2AMetalWritableEncoding *)program
{
    self = [super init];
    if (self)
        _program = program;
    return self;
}
- (instancetype)initFixed:(NV2AMetalEpochResult *)fixed
                 commands:(NV2AMetalCommands *)commands
{
    self = [super init];
    if (self) {
        _fixed = fixed;
        _fixedCommands = commands;
    }
    return self;
}
- (NV2AMetalEpochResult *)fixedResultForCommands:(NV2AMetalCommands *)commands
                                           error:(NSError **)error
{
    if (!_fixed || _program || !commands || commands != _fixedCommands) {
        epoch_error(error, @"Pending Fixed output requires its encoding queue");
        return nil;
    }
    return _fixed;
}
- (NV2AMetalEpochResult *)pendingResultForCommands:(NV2AMetalCommands *)commands
                                             error:(NSError **)error
{
    if (_fixed)
        return [self fixedResultForCommands:commands error:error];
    NV2AMetalWritableResult *r =
        [_program pendingReadOnlyResultForCommands:commands error:error];
    return r ? [[NV2AMetalEpochResult alloc]
                   initRegisters:nil
                        vertices:r.vertexCount ? r.vertices : nil
                           count:r.vertexCount
                       constants:r.constants
                         written:r.written] :
               nil;
}
- (NV2AMetalEpochResult *)resolveWithError:(NSError **)error
{
    if (_fixed)
        return _fixed;
    NV2AMetalWritableResult *r = [_program resolveWithError:error];
    return r ? [[NV2AMetalEpochResult alloc]
                   initRegisters:r.vertexCount ? r.registers : nil
                        vertices:r.vertexCount ? r.vertices : nil
                           count:r.vertexCount
                       constants:r.constants
                         written:r.written] :
               nil;
}
- (NV2AMetalWritableEncoding *)programEncoding
{
    return _program;
}
@end
@implementation NV2AMetalEpochExecutor {
    id<MTLDevice> _device;
    NV2AMetalCommands *_commands;
    NV2AMetalVertexFixed *_fixed;
    NV2AMetalWritableProgram *_program;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    _commands = [[NV2AMetalCommands alloc] initWithDevice:device error:error];
    if (!_commands)
        return nil;
    _fixed = [[NV2AMetalVertexFixed alloc] initWithDevice:device error:error];
    if (!_fixed)
        return nil;
    _program = [[NV2AMetalWritableProgram alloc] initWithDevice:device
                                                          error:error];
    if (!_program)
        return nil;
    _device = device;
    return self;
}
- (NV2AMetalEpochResult *)executeState:(NV2AMetalPGRAPHVertexState *)state
                       attributeBuffer:(id<MTLBuffer>)attributes
                                 first:(NSUInteger)first
                                 count:(NSUInteger)count
                                 error:(NSError **)error
{
    return [self executeState:state
              attributeBuffer:attributes
                        first:first
                        count:count
             compactRegisters:NO
                        error:error];
}
- (NV2AMetalEpochResult *)executeRasterState:(NV2AMetalPGRAPHVertexState *)state
                             attributeBuffer:(id<MTLBuffer>)attributes
                                       first:(NSUInteger)first
                                       count:(NSUInteger)count
                                       error:(NSError **)error
{
    return [self executeState:state
              attributeBuffer:attributes
                        first:first
                        count:count
             compactRegisters:YES
                        error:error];
}
- (NV2AMetalEpochResult *)executeState:(NV2AMetalPGRAPHVertexState *)state
                       attributeBuffer:(id<MTLBuffer>)attributes
                                 first:(NSUInteger)first
                                 count:(NSUInteger)count
                      compactRegisters:(BOOL)compact
                                 error:(NSError **)error
{
    NSUInteger stride = sizeof(NV2AMetalProgramInput);
    if (!state || !attributes || attributes.device != _device ||
        count > UINT32_MAX || first > attributes.length / stride ||
        count > attributes.length / stride - first ||
        count > _device.maxBufferLength / stride) {
        epoch_error(error, @"Invalid captured epoch input range");
        return nil;
    }
    if (state.programmed) {
        NV2AMetalProgramUniforms u = state.programUniforms;
        NV2AMetalWritableResult *r =
            [_program executeProgram:state.validatedProgram
                            uniforms:&u
                     attributeBuffer:attributes
                               first:first
                               count:count
                              access:state.fullAccess ? 1 : 0
                         writeEnable:state.writeEnable
                           rasterize:!state.rasterDiscard
                    compactRegisters:compact
                               error:error];
        return r ? [[NV2AMetalEpochResult alloc]
                       initRegisters:count ? r.registers : nil
                            vertices:count ? r.vertices : nil
                               count:r.vertexCount
                           constants:r.constants
                             written:r.written] :
                   nil;
    }
    NV2AMetalFixedUniforms u = state.fixedUniforms;
    if (!(state.rasterDiscard ? nv2a_metal_fixed_validate_context(&u, error) :
                                nv2a_metal_fixed_validate(&u, error)))
        return nil;
    BOOL discard = compact && state.rasterDiscard;
    NV2AMetalFixedResult *r = nil;
    /* Fixed raw XF writes no context. Once inputs and uniforms are validated,
     * compact callers need only the count and unchanged constant metadata. */
    if (!discard) {
        if (![_commands beginWithError:error])
            return nil;
        r = [_fixed encodeAttributes:attributes
                               first:first
                               count:count
                            uniforms:&u
                           rasterize:!state.rasterDiscard
                    compactRegisters:compact
                            commands:_commands
                               error:error];
        if (!r) {
            [_commands cancel];
            return nil;
        }
        if (![_commands submitWithError:error]) {
            [_commands cancel];
            return nil;
        }
        if (![_commands waitUntilIdleWithError:error])
            return nil;
    }
    uint32_t dirty[192] = { 0 };
    return [[NV2AMetalEpochResult alloc]
        initRegisters:r.registers
             vertices:r.vertices
                count:count
            constants:[NSData dataWithBytes:u.common.constants
                                     length:sizeof(u.common.constants)]
              written:[NSData dataWithBytes:dirty length:sizeof(dirty)]];
}
- (NV2AMetalEpochEncoding *)encodeState:(NV2AMetalPGRAPHVertexState *)state
                        attributeBuffer:(id<MTLBuffer>)attributes
                                  first:(NSUInteger)first
                                  count:(NSUInteger)count
                               commands:(NV2AMetalCommands *)commands
                                  error:(NSError **)error
{
    return [self encodeState:state
             attributeBuffer:attributes
                       first:first
                       count:count
            compactRegisters:NO
                    commands:commands
                       error:error];
}
- (NV2AMetalEpochEncoding *)
    encodeSerialRasterState:(NV2AMetalPGRAPHVertexState *)state
            attributeBuffer:(id<MTLBuffer>)attributes
                      first:(NSUInteger)first
                      count:(NSUInteger)count
                   previous:(NV2AMetalEpochEncoding *)previous
                   commands:(NV2AMetalCommands *)commands
                      error:(NSError **)error
{
    if (!state.programmed || !state.writeEnable ||
        (previous && !previous.programEncoding)) {
        epoch_error(error, @"Invalid serial writable epoch");
        return nil;
    }
    NV2AMetalProgramUniforms u = state.programUniforms;
    NV2AMetalWritableEncoding *program =
        [_program encodeSerialProgram:state.validatedProgram
                             uniforms:&u
                      attributeBuffer:attributes
                                first:first
                                count:count
                               access:state.fullAccess ? 1 : 0
                            rasterize:!state.rasterDiscard
                             previous:previous.programEncoding
                             commands:commands
                                error:error];
    return program ? [[NV2AMetalEpochEncoding alloc] initProgram:program] : nil;
}
- (NV2AMetalEpochEncoding *)encodeRasterState:
                                (NV2AMetalPGRAPHVertexState *)state
                              attributeBuffer:(id<MTLBuffer>)attributes
                                        first:(NSUInteger)first
                                        count:(NSUInteger)count
                                     commands:(NV2AMetalCommands *)commands
                                        error:(NSError **)error
{
    return [self encodeState:state
             attributeBuffer:attributes
                       first:first
                       count:count
            compactRegisters:YES
                    commands:commands
                       error:error];
}
- (NV2AMetalEpochEncoding *)encodeState:(NV2AMetalPGRAPHVertexState *)state
                        attributeBuffer:(id<MTLBuffer>)attributes
                                  first:(NSUInteger)first
                                  count:(NSUInteger)count
                       compactRegisters:(BOOL)compact
                               commands:(NV2AMetalCommands *)commands
                                  error:(NSError **)error
{
    NSUInteger stride = sizeof(NV2AMetalProgramInput);
    if (!state || !attributes || attributes.device != _device ||
        commands.device != _device || !commands.commandBuffer ||
        (state.programmed && state.writeEnable &&
         (!compact || state.validatedProgram.mayWriteConstants)) ||
        count > UINT32_MAX || first > attributes.length / stride ||
        count > attributes.length / stride - first ||
        count > _device.maxBufferLength / stride) {
        epoch_error(error, @"Invalid or writable shared XF epoch");
        return nil;
    }
    if (state.programmed) {
        NV2AMetalProgramUniforms u = state.programUniforms;
        NV2AMetalWritableEncoding *program =
            [_program encodeProgram:state.validatedProgram
                           uniforms:&u
                    attributeBuffer:attributes
                              first:first
                              count:count
                             access:state.fullAccess ? 1 : 0
                        writeEnable:NO
                          rasterize:!state.rasterDiscard
                   compactRegisters:compact
                           commands:commands
                              error:error];
        return program ? [[NV2AMetalEpochEncoding alloc] initProgram:program] :
                         nil;
    }
    NV2AMetalFixedUniforms u = state.fixedUniforms;
    if (!(state.rasterDiscard ? nv2a_metal_fixed_validate_context(&u, error) :
                                nv2a_metal_fixed_validate(&u, error)))
        return nil;
    BOOL discard = compact && state.rasterDiscard;
    NV2AMetalFixedResult *r = discard ?
                                  nil :
                                  [_fixed encodeAttributes:attributes
                                                     first:first
                                                     count:count
                                                  uniforms:&u
                                                 rasterize:!state.rasterDiscard
                                          compactRegisters:compact
                                                  commands:commands
                                                     error:error];
    if (!discard && !r)
        return nil;
    uint32_t dirty[192] = { 0 };
    NV2AMetalEpochResult *result = [[NV2AMetalEpochResult alloc]
        initRegisters:r.registers
             vertices:r.vertices
                count:count
            constants:[NSData dataWithBytes:u.common.constants
                                     length:sizeof(u.common.constants)]
              written:[NSData dataWithBytes:dirty length:sizeof(dirty)]];
    return [[NV2AMetalEpochEncoding alloc] initFixed:result commands:commands];
}
@end
