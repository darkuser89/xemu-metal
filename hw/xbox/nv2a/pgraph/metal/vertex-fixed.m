/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */

#import "vertex-fixed.h"
#import "lru-cache.h"
#include "geometry-types.h"
#include "vertex-fixed-source.h"
#include <math.h>
#include <stddef.h>
#include <stdint.h>

_Static_assert(sizeof(NV2AMetalFixedUniforms) == 5348, "CPU/MSL fixed layout");
_Static_assert(offsetof(NV2AMetalFixedUniforms, specular_params) == 5296,
               "Version-1 capture prefix");
_Static_assert(offsetof(NV2AMetalFixedUniforms, specular_params_back) == 5312,
               "Version-2/3 capture prefix");
_Static_assert(offsetof(NV2AMetalFixedUniforms, skinning) == 5128,
               "CPU/MSL fixed state offset");

static BOOL fixed_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.vertex-fixed"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

static BOOL valid_uniforms(const NV2AMetalFixedUniforms *u, BOOL rasterize)
{
    if (!u ||
        (rasterize && (!isfinite(u->common.surface_size[0]) ||
                       u->common.surface_size[0] <= 0 ||
                       !isfinite(u->common.surface_size[1]) ||
                       u->common.surface_size[1] <= 0 ||
                       !isfinite(u->common.zmax) || u->common.zmax <= 0)) ||
        !isfinite(u->common.point_scale) || u->common.point_scale <= 0 ||
        u->legacy_specular > 1 || u->texgen_infinite_viewer > 1 ||
        u->two_side > 1 ||
        u->back_emission_src > NV2AMetalMaterialSourceSpecular ||
        u->back_ambient_src > NV2AMetalMaterialSourceSpecular ||
        u->back_diffuse_src > NV2AMetalMaterialSourceSpecular ||
        u->back_specular_src > NV2AMetalMaterialSourceSpecular ||
        u->skinning > NV2AMetalSkinningFourWeightsFourMatrices ||
        u->emission_src > NV2AMetalMaterialSourceSpecular ||
        u->ambient_src > NV2AMetalMaterialSourceSpecular ||
        u->diffuse_src > NV2AMetalMaterialSourceSpecular ||
        u->specular_src > NV2AMetalMaterialSourceSpecular ||
        (u->common.fog_enable &&
         (u->foggen > NV2AMetalFoggenFogX || u->common.fog_mode > 7 ||
          u->common.fog_mode == 2 || u->common.fog_mode == 6))) {
        return NO;
    }
    for (unsigned i = 0; i < NV2A_MAX_LIGHTS; i++) {
        if (u->light[i] > NV2AMetalLightSpot) {
            return NO;
        }
    }
    for (unsigned t = 0; t < 4; t++) {
        for (unsigned component = 0; component < 4; component++) {
            unsigned mode = u->texgen[t][component];
            if (mode > NV2AMetalTexgenReflection ||
                (mode == NV2AMetalTexgenSphere && component >= 2) ||
                ((mode == NV2AMetalTexgenNormal ||
                  mode == NV2AMetalTexgenReflection) &&
                 component >= 3)) {
                return NO;
            }
        }
    }
    return YES;
}

BOOL nv2a_metal_fixed_validate(const NV2AMetalFixedUniforms *u, NSError **error)
{
    return valid_uniforms(u, YES) ||
           fixed_error(error, @"Invalid native fixed-function state");
}

BOOL nv2a_metal_fixed_validate_context(const NV2AMetalFixedUniforms *u,
                                       NSError **error)
{
    return valid_uniforms(u, NO) ||
           fixed_error(error, @"Invalid native raw fixed-function state");
}
_Static_assert(sizeof(NV2AMetalFixedParameters) ==
                   sizeof(NV2AMetalFixedUniforms) + 4,
               "Internal fixed execution parameters layout");

@implementation NV2AMetalFixedResult
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

@interface NV2AMetalFixedVariant : NSObject
@property(nonatomic, copy) NSData *key;
@property(nonatomic) unsigned uses;
@property(nonatomic) BOOL queued, finished;
@property(nonatomic) NSArray<id<MTLComputePipelineState>> *pipelines;
@property(nonatomic) NSError *error;
@end
@implementation NV2AMetalFixedVariant
@end

/* Explicit scalar words exclude floats and padded capture storage. */
static void fixed_variant_words(const NV2AMetalFixedUniforms *u,
                                uint32_t words[NV2A_METAL_FIXED_CONSTANT_COUNT])
{
    memset(words, 0, NV2A_METAL_FIXED_CONSTANT_COUNT * sizeof(*words));
#define FF_COPY(Name, Field, Index) words[Index] = u->Field;
    NV2A_METAL_FIXED_SCALAR_CONSTANTS(FF_COPY)
#undef FF_COPY
    _Static_assert(NV2A_MAX_LIGHTS == 8, "Packed fixed light types");
    for (unsigned t = 0; t < 4; t++) {
        words[22] |= (uint32_t)!!u->texture_matrix_enable[t] << t;
        for (unsigned component = 0; component < 4; component++)
            words[24 + t] |= u->texgen[t][component] << (3 * component);
    }
    for (unsigned i = 0; i < NV2A_MAX_LIGHTS; i++)
        words[23] |= u->light[i] << (2 * i);
}

@implementation NV2AMetalVertexFixed {
    id<MTLDevice> _device;
    id<MTL4Compiler> _compiler;
    id<MTLLibrary> _library;
    dispatch_queue_t _specializationQueue;
    NV2AMetalLRUCache<NSData *, NV2AMetalFixedVariant *> *_variants;
    NV2AMetalFixedVariant *_variant;
    uint64_t _specializationAttempts, _specializationPending;
    uint64_t _specializationSuccesses, _specializationFailures;
    uint64_t _specializedDispatches, _generalDispatches;
    id<MTLComputePipelineState> _pipeline, _rasterPipeline;
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
        fixed_error(error,
                    @"Metal 4 fixed-function vertices require Apple Silicon");
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
    function.name = @"nv2a_vertex_fixed";
    MTL4SpecializedFunctionDescriptor *general =
        [MTL4SpecializedFunctionDescriptor new];
    general.functionDescriptor = function;
    general.constantValues = [MTLFunctionConstantValues new];
    MTL4ComputePipelineDescriptor *descriptor =
        [MTL4ComputePipelineDescriptor new];
    descriptor.computeFunctionDescriptor = general;
    _pipeline = [compiler newComputePipelineStateWithDescriptor:descriptor
                                            compilerTaskOptions:nil
                                                          error:error];
    if (!_pipeline) {
        return nil;
    }
    function.name = @"nv2a_vertex_fixed_raster";
    general.functionDescriptor = function;
    descriptor.computeFunctionDescriptor = general;
    _rasterPipeline = [compiler newComputePipelineStateWithDescriptor:descriptor
                                                  compilerTaskOptions:nil
                                                                error:error];
    if (!_rasterPipeline)
        return nil;
    MTL4ArgumentTableDescriptor *arguments = [MTL4ArgumentTableDescriptor new];
    arguments.maxBufferBindCount = 4;
    arguments.initializeBindings = YES;
    _arguments = [device newArgumentTableWithDescriptor:arguments error:error];
    _compiler = compiler;
    _library = library;
    _variants = [[NV2AMetalLRUCache alloc] initWithCapacity:64];
    _specializationQueue = dispatch_queue_create(
        "org.xemu.metal4.fixed-compile",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                QOS_CLASS_UTILITY,0));
    return _arguments && _variants && _specializationQueue ? self : nil;
}

/* Compilation runs only on the instance's serial background queue. */
- (NSArray<id<MTLComputePipelineState>> *)compileVariant:(NSData *)key
                                                 error:(NSError **)error
{
    const uint32_t *words = key.bytes;
    MTLFunctionConstantValues *values = [MTLFunctionConstantValues new];
    for (unsigned i = 0; i < NV2A_METAL_FIXED_CONSTANT_COUNT; i++)
        [values setConstantValue:words+i type:MTLDataTypeUInt atIndex:i];
    NSMutableArray *pipelines = [NSMutableArray new];
    for (NSString *name in @[@"nv2a_vertex_fixed", @"nv2a_vertex_fixed_raster"]) {
        MTL4LibraryFunctionDescriptor *function =
            [MTL4LibraryFunctionDescriptor new];
        function.library = _library;
        function.name = name;
        MTL4SpecializedFunctionDescriptor *specialized =
            [MTL4SpecializedFunctionDescriptor new];
        specialized.functionDescriptor = function;
        specialized.constantValues = values;
        MTL4ComputePipelineDescriptor *descriptor =
            [MTL4ComputePipelineDescriptor new];
        descriptor.computeFunctionDescriptor = specialized;
        id<MTLComputePipelineState> pipeline =
            [_compiler newComputePipelineStateWithDescriptor:descriptor
                                         compilerTaskOptions:nil
                                                       error:error];
        if (!pipeline)
            return nil;
        [pipelines addObject:pipeline];
    }
    return [pipelines copy];
}
- (id<MTLComputePipelineState>)pipelineForUniforms:
                                   (const NV2AMetalFixedUniforms *)u
                                           compact:(BOOL)compact
{
    uint32_t words[NV2A_METAL_FIXED_CONSTANT_COUNT];
    fixed_variant_words(u, words);
    NV2AMetalFixedVariant *variant = _variant;
    if (!variant || memcmp(variant.key.bytes, words, sizeof(words))) {
        NSData *key = [NSData dataWithBytes:words length:sizeof(words)];
        variant = _variants[key];
        if (!variant) {
            variant = [NV2AMetalFixedVariant new];
            variant.key = key;
            _variants[key] = variant;
        }
        _variant = variant;
    }
    @synchronized(variant) {
        if (variant.pipelines) {
            _specializedDispatches++;
            return variant.pipelines[compact ? 1 : 0];
        }
        if (variant.uses < 4)
            variant.uses++;
    }
    /* General GPU execution continues while cold or compiling. Up to two
     * jobs may retain entries outside the64-entry/two-pipelines-per-entry LRU.
     */
    @synchronized(self) {
        @synchronized(variant) {
            if (variant.uses == 4 && !variant.queued && !variant.finished &&
                _specializationPending < 2) {
                variant.queued = YES;
                _specializationPending++;
                _specializationAttempts++;
                dispatch_async(_specializationQueue, ^{
                  @autoreleasepool {
                      NSError *error = nil;
                      NSArray *pipelines = [self compileVariant:variant.key
                                                          error:&error];
                      @synchronized(variant) {
                          variant.pipelines = pipelines;
                          variant.error = error;
                          variant.finished = YES;
                      }
                      @synchronized(self) {
                          _specializationPending--;
                          if (pipelines)
                              _specializationSuccesses++;
                          else
                              _specializationFailures++;
                      }
                  }
                });
            }
        }
    }
    _generalDispatches++;
    return compact ? _rasterPipeline : _pipeline;
}

- (nullable NV2AMetalFixedResult *)
    encodeAttributes:(id<MTLBuffer>)attributes
               count:(NSUInteger)count
            uniforms:(const NV2AMetalFixedUniforms *)uniforms
            commands:(NV2AMetalCommands *)commands
               error:(NSError **)error
{
    return [self encodeAttributes:attributes
                            count:count
                         uniforms:uniforms
                        rasterize:YES
                         commands:commands
                            error:error];
}
- (nullable NV2AMetalFixedResult *)
    encodeAttributes:(id<MTLBuffer>)attributes
               count:(NSUInteger)count
            uniforms:(const NV2AMetalFixedUniforms *)uniforms
           rasterize:(BOOL)rasterize
            commands:(NV2AMetalCommands *)commands
               error:(NSError **)error
{
    return [self encodeAttributes:attributes
                            first:0
                            count:count
                         uniforms:uniforms
                        rasterize:rasterize
                         commands:commands
                            error:error];
}
- (nullable NV2AMetalFixedResult *)
    encodeAttributes:(id<MTLBuffer>)attributes
               first:(NSUInteger)first
               count:(NSUInteger)count
            uniforms:(const NV2AMetalFixedUniforms *)uniforms
           rasterize:(BOOL)rasterize
            commands:(NV2AMetalCommands *)commands
               error:(NSError **)error
{
    return [self encodeAttributes:attributes
                            first:first
                            count:count
                         uniforms:uniforms
                        rasterize:rasterize
                 compactRegisters:NO
                         commands:commands
                            error:error];
}
- (nullable NV2AMetalFixedResult *)
    encodeAttributes:(id<MTLBuffer>)attributes
               first:(NSUInteger)first
               count:(NSUInteger)count
            uniforms:(const NV2AMetalFixedUniforms *)uniforms
           rasterize:(BOOL)rasterize
    compactRegisters:(BOOL)compact
            commands:(NV2AMetalCommands *)commands
               error:(NSError **)error
{
    if ((compact != YES && compact != NO) ||
        (rasterize != YES && rasterize != NO) || !commands.commandBuffer ||
        commands.device != _device || attributes.device != _device ||
        count > UINT32_MAX ||
        first > attributes.length / sizeof(NV2AMetalProgramInput) ||
        count > attributes.length / sizeof(NV2AMetalProgramInput) - first ||
        count > _device.maxBufferLength / sizeof(NV2AMetalVertex) ||
        count > _device.maxBufferLength / sizeof(NV2AMetalProgramOutput) ||
        !(rasterize ? nv2a_metal_fixed_validate(uniforms, error) :
                      nv2a_metal_fixed_validate_context(uniforms, error))) {
        fixed_error(error, @"Invalid Metal fixed-function input or recording");
        return nil;
    }
    if (!count) {
        return [[NV2AMetalFixedResult alloc] initWithRegisters:nil
                                                      vertices:nil
                                                         count:0];
    }
    NV2AMetalFixedParameters parameters = { .uniforms = *uniforms,
                                            .rasterize = rasterize };
    parameters.uniforms.common.vertex_count = (unsigned)count;
    NSUInteger constantsOffset = 0;
    id<MTLBuffer> constants = [commands uploadBytes:&parameters
                                             length:sizeof(parameters)
                                             offset:&constantsOffset
                                              error:error];
    if (!constants) {
        return nil;
    }
    id<MTLBuffer> registers =
        compact ?
            nil :
            [_device newBufferWithLength:count * sizeof(NV2AMetalProgramOutput)
                                 options:MTLResourceStorageModeShared];
    id<MTLBuffer> vertices =
        [_device newBufferWithLength:count * sizeof(NV2AMetalVertex)
                             options:MTLResourceStorageModeShared];
    if ((!compact && !registers) || !vertices) {
        fixed_error(error, @"Could not allocate Metal fixed-function buffers");
        return nil;
    }
    if (![commands addResource:attributes error:error] ||
        (!compact && ![commands addResource:registers error:error]) ||
        ![commands addResource:vertices error:error] ||
        ![commands keepAlive:self error:error]) {
        return nil;
    }
    id<MTLComputePipelineState> pipeline = [self pipelineForUniforms:uniforms
                                                             compact:compact];
    if (![commands keepAlive:pipeline error:error])
        return nil;
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        fixed_error(error, @"Could not create Metal fixed-function encoder");
        return nil;
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageDispatch
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [_arguments
        setAddress:attributes.gpuAddress + first * sizeof(NV2AMetalProgramInput)
           atIndex:0];
    [_arguments setAddress:compact ? 0 : registers.gpuAddress atIndex:1];
    [_arguments setAddress:vertices.gpuAddress atIndex:2];
    [_arguments setAddress:constants.gpuAddress + constantsOffset atIndex:3];
    [encoder setArgumentTable:_arguments];
    [encoder setComputePipelineState:pipeline];
    NSUInteger width = pipeline.threadExecutionWidth;
    if (width > count) {
        width = count;
    }
    [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
    [encoder barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return [[NV2AMetalFixedResult alloc] initWithRegisters:registers
                                                  vertices:vertices
                                                     count:count];
}
@end
