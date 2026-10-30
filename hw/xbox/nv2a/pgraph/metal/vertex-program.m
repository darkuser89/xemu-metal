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
#include "geometry-types.h"
#include "vertex-program-source.h"
#include <math.h>
#include <stddef.h>
#include <stdint.h>

_Static_assert(sizeof(NV2AMetalProgramInput) == 256,
               "CPU/MSL attribute layout");
_Static_assert(sizeof(NV2AMetalProgramOutput) == 224,
               "CPU/MSL register layout");
_Static_assert(sizeof(NV2AMetalProgramUniforms) == 3136,
               "CPU/MSL uniform layout");
_Static_assert(sizeof(NV2AMetalProgramInstruction) == 56,
               "CPU/MSL instruction layout");
_Static_assert(offsetof(NV2AMetalProgramUniforms, vertex_count) == 3120,
               "CPU/MSL dispatch offset");

static BOOL program_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.vertex-program"
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
        .output_register = (token[3] >> 3) & 15,
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
        if (mux == 0 || (mux == 1 && reg > 12) ||
            (mux == 3 && !op->relative &&
             op->constant_index >= NV2A_METAL_VP_CONSTANTS)) {
            return program_error(error, @"Invalid NV2A vertex-program operand");
        }
    }
    if (op->temp_register > 12 &&
        ((op->mac != NV2AMetalMACNop && op->mac != NV2AMetalMACArl &&
          op->mac_mask) ||
         (op->mac == NV2AMetalMACNop && op->ilu != NV2AMetalILUNop &&
          op->ilu_mask))) {
        return program_error(error, @"Invalid NV2A temporary destination");
    }
    BOOL output =
        op->output_mask && (op->output_mux == 0 ? op->mac != NV2AMetalMACNop :
                                                  op->ilu != NV2AMetalILUNop);
    if (output && (!(token[3] & (1u << 11)) || op->output_register == 1 ||
                   op->output_register == 2 || op->output_register > 12 ||
                   (op->output_mux == 0 && op->mac == NV2AMetalMACArl))) {
        return program_error(error,
                             @"Unsupported NV2A constant/address/output write");
    }
    return YES;
}

static BOOL program_uniforms_valid(const NV2AMetalProgramUniforms *u)
{
    return u && isfinite(u->surface_size[0]) && u->surface_size[0] > 0 &&
           isfinite(u->surface_size[1]) && u->surface_size[1] > 0 &&
           isfinite(u->zmax) && u->zmax > 0 && isfinite(u->point_scale) &&
           u->point_scale > 0 &&
           (!u->fog_enable ||
            (u->fog_mode <= 7 && u->fog_mode != 2 && u->fog_mode != 6));
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
BOOL nv2a_metal_program_validate(const uint32_t *tokens, NSUInteger length,
                                 const NV2AMetalProgramUniforms *u,
                                 NSError **error)
{
    if (!program_uniforms_valid(u)) {
        return program_error(error, @"Invalid Metal vertex-program uniforms");
    }
    NV2AMetalProgramInstruction decoded[NV2A_METAL_VP_SLOTS];
    NSUInteger slots;
    return decode_program(tokens, length, decoded, &slots, error);
}

@implementation NV2AMetalProgramResult
- (instancetype)initWithRegisters:(id<MTLBuffer>)registers
                         vertices:(id<MTLBuffer>)vertices
                            count:(NSUInteger)count
{
    self = [super init];
    if (self) {
        _registers = registers;
        _vertices = vertices;
        _vertexCount = count;
    }
    return self;
}
@end

@implementation NV2AMetalVertexProgram {
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
        program_error(error, @"Metal 4 vertex programs require Apple Silicon");
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
    function.name = @"nv2a_vertex_program";
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
    arguments.maxBufferBindCount = 5;
    arguments.initializeBindings = YES;
    _arguments = [device newArgumentTableWithDescriptor:arguments error:error];
    return _arguments ? self : nil;
}

- (nullable NV2AMetalProgramResult *)
    encodeTokens:(const uint32_t *)tokens
          length:(NSUInteger)length
        uniforms:(const NV2AMetalProgramUniforms *)uniforms
      attributes:(id<MTLBuffer>)attributes
           count:(NSUInteger)count
        commands:(NV2AMetalCommands *)commands
           error:(NSError **)error
{
    if (!tokens || !uniforms || !length || length > NV2A_METAL_VP_SLOTS ||
        !commands.commandBuffer || commands.device != _device ||
        attributes.device != _device || count > UINT32_MAX ||
        count > attributes.length / sizeof(NV2AMetalProgramInput) ||
        count > _device.maxBufferLength / sizeof(NV2AMetalVertex) ||
        count > _device.maxBufferLength / sizeof(NV2AMetalProgramOutput) ||
        !program_uniforms_valid(uniforms)) {
        program_error(error,
                      @"Invalid Metal vertex-program input or recording");
        return nil;
    }
    NV2AMetalProgramInstruction decoded[NV2A_METAL_VP_SLOTS];
    NSUInteger slots;
    if (!decode_program(tokens, length, decoded, &slots, error))
        return nil;
    if (!count) {
        return [[NV2AMetalProgramResult alloc] initWithRegisters:nil
                                                        vertices:nil
                                                           count:0];
    }
    NV2AMetalProgramUniforms u = *uniforms;
    u.vertex_count = (unsigned)count;
    u.program_length = (unsigned)slots;
    NSUInteger constantsOffset = 0;
    id<MTLBuffer> constants = [commands uploadBytes:&u
                                             length:sizeof(u)
                                             offset:&constantsOffset
                                              error:error];
    if (!constants) {
        return nil;
    }
    id<MTLBuffer> program =
        [_device newBufferWithBytes:decoded
                             length:slots * sizeof(decoded[0])
                            options:MTLResourceStorageModeShared];
    id<MTLBuffer> registers =
        [_device newBufferWithLength:count * sizeof(NV2AMetalProgramOutput)
                             options:MTLResourceStorageModeShared];
    id<MTLBuffer> vertices =
        [_device newBufferWithLength:count * sizeof(NV2AMetalVertex)
                             options:MTLResourceStorageModeShared];
    if (!program || !registers || !vertices) {
        program_error(error,
                      @"Could not allocate Metal vertex-program buffers");
        return nil;
    }
    if (![commands addResource:attributes error:error] ||
        ![commands addResource:program error:error] ||
        ![commands addResource:registers error:error] ||
        ![commands addResource:vertices error:error] ||
        ![commands keepAlive:self error:error]) {
        return nil;
    }
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        program_error(error, @"Could not create Metal vertex-program encoder");
        return nil;
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageDispatch
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [_arguments setAddress:attributes.gpuAddress atIndex:0];
    [_arguments setAddress:registers.gpuAddress atIndex:1];
    [_arguments setAddress:vertices.gpuAddress atIndex:2];
    [_arguments setAddress:constants.gpuAddress + constantsOffset atIndex:3];
    [_arguments setAddress:program.gpuAddress atIndex:4];
    [encoder setArgumentTable:_arguments];
    [encoder setComputePipelineState:_pipeline];
    NSUInteger width = _pipeline.threadExecutionWidth;
    if (width > count) {
        width = count;
    }
    [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
    [encoder barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return [[NV2AMetalProgramResult alloc] initWithRegisters:registers
                                                    vertices:vertices
                                                       count:count];
}
@end
