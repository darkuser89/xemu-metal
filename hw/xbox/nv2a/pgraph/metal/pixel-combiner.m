/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */

#import "pixel-combiner.h"
#include "pixel-combiner-source.h"
#include <stdint.h>

_Static_assert(sizeof(NV2AMetalCombinerState) == 432, "CPU/MSL combiner state");
_Static_assert(sizeof(NV2AMetalCombinerInput) == 112, "CPU/MSL combiner input");
_Static_assert(sizeof(NV2AMetalCombinerOutput) == 272,
               "CPU/MSL combiner output");

static BOOL combiner_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.pixel-combiner"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

static BOOL valid_input(unsigned input, BOOL allowEF)
{
    unsigned reg = input & 15;
    return reg != 6 && reg != 7 && (allowEF || reg != PS_REGISTER_EF_PROD);
}

static BOOL valid_inputs(unsigned inputs, unsigned count, BOOL allowEF)
{
    for (unsigned i = 0; i < count; i++) {
        if (!valid_input(inputs >> (24 - 8 * i), allowEF)) {
            return NO;
        }
    }
    return YES;
}

static BOOL valid_destination(unsigned reg)
{
    /* FOG is a mutable local in the reference GL shader. Constant registers
     * and synthetic SUM/EF expressions are not valid assignment targets. */
    return reg == PS_REGISTER_DISCARD || reg == PS_REGISTER_FOG ||
           reg == PS_REGISTER_V0 || reg == PS_REGISTER_V1 ||
           (reg >= PS_REGISTER_T0 && reg <= PS_REGISTER_R1);
}

BOOL nv2a_metal_combiner_validate(const NV2AMetalCombinerState *state,
                                  NSError **error)
{
    if (!state || (state->control & 255) > 8 ||
        !(state->final_inputs[0] || state->final_inputs[1]) ||
        !valid_inputs(state->final_inputs[0], 4, YES) ||
        !valid_inputs(state->final_inputs[1], 2, NO) ||
        !valid_input(state->final_inputs[1] >> 8, YES)) {
        return combiner_error(error,
                              @"Invalid or undefined Metal final combiner");
    }
    for (unsigned i = 0; i < (state->control & 255); i++) {
        unsigned outputs[] = { state->rgb_outputs[i], state->alpha_outputs[i] };
        if (!valid_inputs(state->rgb_inputs[i], 4, NO) ||
            !valid_inputs(state->alpha_inputs[i], 4, NO)) {
            return combiner_error(error,
                                  @"Invalid Metal combiner input register");
        }
        for (unsigned p = 0; p < 2; p++) {
            unsigned word = outputs[p];
            unsigned mapping = (word >> 12) & 0x38;
            if (mapping == 0x28 || mapping == 0x38 ||
                !valid_destination(word & 15) ||
                !valid_destination((word >> 4) & 15) ||
                !valid_destination((word >> 8) & 15)) {
                return combiner_error(error, @"Invalid Metal combiner output");
            }
        }
    }
    return YES;
}

@implementation NV2AMetalCombinerResult
- (instancetype)initWithOutputs:(id<MTLBuffer>)outputs count:(NSUInteger)count
{
    self = [super init];
    if (self) {
        _outputs = outputs;
        _count = count;
    }
    return self;
}
@end

@implementation NV2AMetalPixelCombiner {
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
        combiner_error(error, @"Metal 4 pixel combiners require Apple Silicon");
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
    function.name = @"nv2a_pixel_combiner";
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
    arguments.maxBufferBindCount = 4;
    arguments.initializeBindings = YES;
    _arguments = [device newArgumentTableWithDescriptor:arguments error:error];
    return _arguments ? self : nil;
}

- (nullable NV2AMetalCombinerResult *)
    encodeInputs:(id<MTLBuffer>)inputs
           count:(NSUInteger)count
          states:(const NV2AMetalCombinerState *)states
      stateCount:(NSUInteger)stateCount
        commands:(NV2AMetalCommands *)commands
           error:(NSError **)error
{
    if (!commands.commandBuffer || commands.device != _device ||
        inputs.device != _device || !states ||
        (stateCount != 1 && stateCount != count) || !stateCount ||
        count > UINT32_MAX ||
        count > inputs.length / sizeof(NV2AMetalCombinerInput) ||
        count > _device.maxBufferLength / sizeof(NV2AMetalCombinerOutput) ||
        stateCount > _device.maxBufferLength / sizeof(*states)) {
        combiner_error(error,
                       @"Invalid Metal pixel combiner batch or recording");
        return nil;
    }
    for (NSUInteger i = 0; i < stateCount; i++) {
        if (!nv2a_metal_combiner_validate(&states[i], error)) {
            return nil;
        }
    }
    if (!count) {
        return [[NV2AMetalCombinerResult alloc] initWithOutputs:nil count:0];
    }
    id<MTLBuffer> result =
        [_device newBufferWithLength:count * sizeof(NV2AMetalCombinerOutput)
                             options:MTLResourceStorageModeShared];
    if (!result) {
        combiner_error(error,
                       @"Could not allocate Metal pixel combiner output");
        return nil;
    }
    id<MTLBuffer> constants =
        [_device newBufferWithBytes:states
                             length:stateCount * sizeof(*states)
                            options:MTLResourceStorageModeShared];
    NV2AMetalCombinerDispatch d = { (unsigned)count, (unsigned)stateCount };
    id<MTLBuffer> dispatch =
        [_device newBufferWithBytes:&d
                             length:sizeof(d)
                            options:MTLResourceStorageModeShared];
    if (!constants || !dispatch) {
        combiner_error(error, @"Could not allocate Metal pixel combiner state");
        return nil;
    }
    if (![commands addResource:inputs error:error] ||
        ![commands addResource:constants error:error] ||
        ![commands addResource:result error:error] ||
        ![commands addResource:dispatch error:error] ||
        ![commands keepAlive:self error:error]) {
        return nil;
    }
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        combiner_error(error, @"Could not create Metal pixel combiner encoder");
        return nil;
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageDispatch
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [_arguments setAddress:inputs.gpuAddress atIndex:0];
    [_arguments setAddress:constants.gpuAddress atIndex:1];
    [_arguments setAddress:result.gpuAddress atIndex:2];
    [_arguments setAddress:dispatch.gpuAddress atIndex:3];
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
    return [[NV2AMetalCombinerResult alloc] initWithOutputs:result count:count];
}
@end
