/*
 * NV2A token decoding follows glsl/vsh-prog.c's field_mapping and vsh_regs.h
 * Copyright (c) 2012 espes
 * Copyright (c) 2014 Jannik Vogel
 * Copyright (c) 2025 Matt Borgerson
 * Based on Cxbx, VertexShader.cpp:
 * Copyright (c) 2004 Aaron Robinson and Kingofc
 * and Dxbx, uPushBuffer.pas:
 * Copyright (c) 2007 Shadow_tj and PatrickvL
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only
 */

#import "vertex-program.h"
static BOOL program_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.vertex-state"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

/* Translate the verified NV2A fields once on the CPU. The packed source below
 * is internal to this backend and never used as a hardware definition. */
static NV2AMetalProgramInstruction decode_token(const uint32_t *token)
{
    NV2AMetalProgramInstruction op = {
        .mac = (token[1] >> 21) & 15,
        .ilu = (token[1] >> 25) & 7,
        .constant_index = (token[1] >> 13) & 255,
        .attribute_index = (token[1] >> 9) & 15,
        .mac_mask = (token[3] >> 24) & 15,
        .ilu_mask = (token[3] >> 16) & 15,
        .output_mask = (token[3] >> 12) & 15,
        .output_register = (token[3] >> 3) & 255,
        .output_mux = (token[3] >> 2) & 1,
        .temp_register = (token[3] >> 20) & 15,
        .relative = (token[3] >> 1) & 1,
    };
    unsigned mux[] = { (token[2] >> 26) & 3, (token[2] >> 11) & 3,
                       (token[3] >> 28) & 3 };
    unsigned reg[] = { token[2] >> 28, (token[2] >> 13) & 15,
                       ((token[2] & 3) << 2) | (token[3] >> 30) };
    unsigned neg[] = { (token[1] >> 8) & 1, (token[2] >> 25) & 1,
                       (token[2] >> 10) & 1 };
    for (unsigned s = 0; s < 3; s++) {
        op.source[s] = mux[s] | (reg[s] << 2) | (neg[s] << 14);
        unsigned word = s == 0 ? token[1] : token[2];
        unsigned start = s == 0 ? 6 : s == 1 ? 23 : 8;
        for (unsigned component = 0; component < 4; component++) {
            op.source[s] |= ((word >> (start - 2 * component)) & 3)
                            << (6 + 2 * component);
        }
    }
    return op;
}

static BOOL valid_instruction(const NV2AMetalProgramInstruction *op,
                              const uint32_t *token, NSError **error)
{
    if (op->mac > NV2AMetalMACArl || op->ilu > NV2AMetalILULit) {
        return program_error(error, @"Invalid NV2A vertex-program opcode");
    }
    BOOL needed[] = {
        op->mac != NV2AMetalMACNop,
        op->mac != NV2AMetalMACNop && op->mac != NV2AMetalMACMov &&
            op->mac != NV2AMetalMACAdd && op->mac != NV2AMetalMACArl,
        op->mac == NV2AMetalMACAdd || op->mac == NV2AMetalMACMad ||
            op->ilu != NV2AMetalILUNop,
    };
    for (unsigned s = 0; s < 3; s++) {
        if (!needed[s]) {
            continue;
        }
        unsigned mux = op->source[s] & 3;
        unsigned reg = (op->source[s] >> 2) & 15;
        if ((mux == 2 && op->attribute_index != 0) || mux == 0 ||
            (mux == 1 && reg > 11) ||
            (mux == 3 && !op->relative &&
             op->constant_index >= NV2A_METAL_VP_CONSTANTS)) {
            return program_error(error, @"Invalid NV2A vertex-program operand");
        }
    }
    if (op->temp_register > 11 &&
        ((op->mac != NV2AMetalMACNop && op->mac != NV2AMetalMACArl &&
          op->mac_mask) ||
         (op->mac == NV2AMetalMACNop && op->ilu != NV2AMetalILUNop &&
          op->ilu_mask))) {
        return program_error(error, @"Invalid NV2A temporary destination");
    }
    BOOL output =
        op->output_mask && (op->output_mux == 0 ? op->mac != NV2AMetalMACNop :
                                                  op->ilu != NV2AMetalILUNop);
    if (output && ((token[3] & (1u << 11)) || op->output_register >= 192 ||
                   (op->output_mux == 0 && op->mac == NV2AMetalMACArl))) {
        return program_error(
            error, @"Unsupported state-program vertex/address/context write");
    }
    return YES;
}

static BOOL decode_program(const uint32_t *tokens, NSUInteger length,
                           NV2AMetalProgramInstruction *decoded,
                           NSUInteger *slots, NSError **error)
{
    if (!tokens || !length || length > NV2A_METAL_VP_SLOTS) {
        return program_error(error, @"Invalid NV2A vertex program span");
    }
    BOOL final = NO;
    for (*slots = 0; *slots < length; (*slots)++) {
        decoded[*slots] = decode_token(tokens + 4 * (*slots));
        if (!valid_instruction(&decoded[*slots], tokens + 4 * (*slots),
                               error)) {
            return NO;
        }
        if (tokens[4 * (*slots) + 3] & 1) {
            (*slots)++;
            final = YES;
            break;
        }
    }
    if (!final) {
        program_error(error, @"NV2A vertex program has no final instruction");
        return NO;
    }
    return YES;
}


#include <string.h>
#include "vertex-state.h"
#include "vertex-context-types.h"
#include "vertex-context-source.h"
_Static_assert(sizeof(NV2AMetalStateInput) == 3328, "State input transport");
_Static_assert(sizeof(NV2AMetalStateOutput) == 3856, "State output transport");
@interface NV2AMetalStateResult ()
- (instancetype)initWithSnapshot:(const NV2AMetalStateOutput *)snapshot;
@end
@implementation NV2AMetalStateResult
- (instancetype)initWithSnapshot:(const NV2AMetalStateOutput *)snapshot
{
    self = [super init];
    if (self) {
        _constants = [NSData dataWithBytes:snapshot->constants
                                    length:sizeof(snapshot->constants)];
        _written = [NSData dataWithBytes:snapshot->dirty
                                  length:sizeof(snapshot->dirty)];
    }
    return self;
}
@end

@implementation NV2AMetalStateProgram {
    NV2AMetalCommands *_commands;
    id<MTLComputePipelineState> _pipeline;
    id<MTL4ArgumentTable> _arguments;
}
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    _commands = [[NV2AMetalCommands alloc] initWithDevice:device error:error];
    if (!_commands)
        return nil;
    id<MTL4Compiler> compiler =
        [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                    error:error];
    if (!compiler)
        return nil;
    MTL4LibraryDescriptor *libraryDescriptor = [MTL4LibraryDescriptor new];
    libraryDescriptor.source = @(metal_shader_source);
    libraryDescriptor.options = [MTLCompileOptions new];
    libraryDescriptor.options.languageVersion = MTLLanguageVersion4_0;
    libraryDescriptor.options.mathMode = MTLMathModeSafe;
    libraryDescriptor.options.mathFloatingPointFunctions =
        MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> library =
        [compiler newLibraryWithDescriptor:libraryDescriptor error:error];
    if (!library)
        return nil;
    MTL4LibraryFunctionDescriptor *function =
        [MTL4LibraryFunctionDescriptor new];
    function.library = library;
    function.name = @"nv2a_state_program";
    MTL4ComputePipelineDescriptor *descriptor =
        [MTL4ComputePipelineDescriptor new];
    descriptor.computeFunctionDescriptor = function;
    _pipeline = [compiler newComputePipelineStateWithDescriptor:descriptor
                                            compilerTaskOptions:nil
                                                          error:error];
    if (!_pipeline)
        return nil;
    MTL4ArgumentTableDescriptor *arguments = [MTL4ArgumentTableDescriptor new];
    arguments.maxBufferBindCount = 4;
    arguments.initializeBindings = YES;
    _arguments = [device newArgumentTableWithDescriptor:arguments error:error];
    return _arguments ? self : nil;
}
- (nullable NV2AMetalStateResult *)executeTokens:(const uint32_t *)tokens
                                          length:(NSUInteger)length
                                       constants:(NSData *)constants
                                          launch:(NSData *)launch
                                           error:(NSError **)error
{
    return [self executeTokens:tokens
                        length:length
                     constants:constants
                        launch:launch
                        access:NV2AMetalStateFull
                         error:error];
}
- (nullable NV2AMetalStateResult *)executeTokens:(const uint32_t *)tokens
                                          length:(NSUInteger)length
                                       constants:(NSData *)constants
                                          launch:(NSData *)launch
                                          access:(NV2AMetalStateAccess)access
                                           error:(NSError **)error
{
    if (access != NV2AMetalStateUserOnly && access != NV2AMetalStateFull) {
        program_error(error, @"Invalid Metal state-program access aperture");
        return nil;
    }
    if (constants.length != 192 * 4 * sizeof(uint32_t) ||
        launch.length != 4 * sizeof(uint32_t)) {
        program_error(error, @"Invalid Metal state-program input snapshots");
        return nil;
    }
    NV2AMetalProgramInstruction decoded[NV2A_METAL_VP_SLOTS];
    NSUInteger slots = 0;
    if (!decode_program(tokens, length, decoded, &slots, error))
        return nil;
    NV2AMetalStateInput input = { 0 };
    memcpy(input.constants, constants.bytes, constants.length);
    memcpy(input.attributes.attributes[0], launch.bytes, launch.length);
    NV2AMetalStateParameters parameters = { 0 };
    parameters.common.vertex_count = 1;
    parameters.common.program_length = (unsigned)slots;
    parameters.full_access = access == NV2AMetalStateFull;
    id<MTLDevice> device = _commands.device;
    id<MTLBuffer> inputs =
        [device newBufferWithBytes:&input
                            length:sizeof(input)
                           options:MTLResourceStorageModeShared];
    id<MTLBuffer> output =
        [device newBufferWithLength:sizeof(NV2AMetalStateOutput)
                            options:MTLResourceStorageModeShared];
    id<MTLBuffer> uniformBuffer =
        [device newBufferWithBytes:&parameters
                            length:sizeof(parameters)
                           options:MTLResourceStorageModeShared];
    id<MTLBuffer> program =
        [device newBufferWithBytes:decoded
                            length:slots * sizeof(decoded[0])
                           options:MTLResourceStorageModeShared];
    if (!inputs || !output || !uniformBuffer || !program) {
        program_error(error, @"Could not allocate Metal state-program buffers");
        return nil;
    }
    if (![_commands beginWithError:error])
        return nil;
    for (id<MTLBuffer> buffer in @[ inputs, output, uniformBuffer, program ]) {
        if (![_commands addResource:buffer error:error]) {
            [_commands cancel];
            return nil;
        }
    }
    id<MTL4ComputeCommandEncoder> encoder =
        [_commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        program_error(error, @"Could not create Metal state-program encoder");
        [_commands cancel];
        return nil;
    }
    [_arguments setAddress:inputs.gpuAddress atIndex:0];
    [_arguments setAddress:output.gpuAddress atIndex:1];
    [_arguments setAddress:uniformBuffer.gpuAddress atIndex:2];
    [_arguments setAddress:program.gpuAddress atIndex:3];
    [encoder setArgumentTable:_arguments];
    [encoder setComputePipelineState:_pipeline];
    [encoder dispatchThreads:MTLSizeMake(1, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [encoder barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    if (![_commands submitWithError:error]) {
        [_commands cancel];
        return nil;
    }
    if (![_commands waitUntilIdleWithError:error])
        return nil;
    const NV2AMetalStateOutput *snapshot = output.contents;
    if (snapshot->fault) {
        program_error(error, @"Metal state-program dynamic address fault");
        return nil;
    }
    for (unsigned i = 0; i < 192; i++) {
        if (snapshot->dirty[i] > 1) {
            program_error(error, @"Invalid Metal state-program write flags");
            return nil;
        }
    }
    return [[NV2AMetalStateResult alloc] initWithSnapshot:snapshot];
}
@end
