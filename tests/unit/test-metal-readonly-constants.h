/* Direct uniform constants: GPU size, all apertures and old-kernel parity.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_READONLY_CONSTANTS_H
#define TEST_METAL_READONLY_CONSTANTS_H
#import <objc/runtime.h>
#define metal_shader_source readonly_constant_shader_source
#include "hw/xbox/nv2a/pgraph/metal/vertex-context-source.h"
#undef metal_shader_source

static id<MTLComputePipelineState>
readonly_constant_pipeline(id<MTL4Compiler> compiler, id<MTLLibrary> library,
                           NSString *name)
{
    NSError *error = nil;
    MTL4LibraryFunctionDescriptor *function =
        [MTL4LibraryFunctionDescriptor new];
    function.library = library;
    function.name = name;
    MTL4ComputePipelineDescriptor *descriptor =
        [MTL4ComputePipelineDescriptor new];
    descriptor.computeFunctionDescriptor = function;
    id<MTLComputePipelineState> pipeline =
        [compiler newComputePipelineStateWithDescriptor:descriptor
                                    compilerTaskOptions:nil
                                                  error:&error];
    require(pipeline != nil, error);
    return pipeline;
}
static id<MTLLibrary> readonly_constant_library(id<MTL4Compiler> compiler,
                                                NSString *source)
{
    NSError *error = nil;
    MTL4LibraryDescriptor *descriptor = [MTL4LibraryDescriptor new];
    descriptor.source = source;
    descriptor.options = [MTLCompileOptions new];
    descriptor.options.languageVersion = MTLLanguageVersion4_0;
    descriptor.options.mathMode = MTLMathModeSafe;
    descriptor.options.mathFloatingPointFunctions =
        MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:descriptor
                                                          error:&error];
    require(library != nil, error);
    return library;
}
static NSArray<NSNumber *> *readonly_constant_sizes(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    NSString *source = [@(readonly_constant_shader_source)
        stringByAppendingString:
            @"\nkernel void nv2a_test_register_sizes(device uint *out "
            @"[[buffer(0)]]) {"
             " out[0] = sizeof(VPRegisters); out[1] = "
             "sizeof(VPReadOnlyRegisters);"
             " out[2] = NV2A_METAL_VP_CONSTANTS * sizeof(float4);"
             " out[3] = NV2A_METAL_VP_CONSTANTS * sizeof(uint); }\n"];
    id<MTLLibrary> library = readonly_constant_library(compiler, source);
    id<MTLComputePipelineState> pipeline = readonly_constant_pipeline(
        compiler, library, @"nv2a_test_register_sizes");
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:16
                                     options:MTLResourceStorageModeShared];
    assert(output);
    MTL4ArgumentTableDescriptor *description =
        [MTL4ArgumentTableDescriptor new];
    description.maxBufferBindCount = 1;
    description.initializeBindings = YES;
    id<MTL4ArgumentTable> table =
        [commands.device newArgumentTableWithDescriptor:description
                                                  error:&error];
    require(table != nil, error);
    [table setAddress:output.gpuAddress atIndex:0];
    require([commands beginWithError:&error] != nil, error);
    require([commands addResource:output error:&error], error);
    require([commands keepAlive:table error:&error], error);
    require([commands keepAlive:pipeline error:&error], error);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder setComputePipelineState:pipeline];
    [encoder setArgumentTable:table];
    [encoder dispatchThreads:MTLSizeMake(1, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [encoder barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    const uint32_t *sizes = output.contents;
    assert(sizes[2] == 3072 && sizes[3] == 768);
    assert(sizes[0] - sizes[1] == sizes[2] + sizes[3]);
    printf("Readonly register structures: writable=%u readonly=%u delta=%u "
           "bytes PASS\n",
           sizes[0], sizes[1], sizes[0] - sizes[1]);
    return @[ @(sizes[0]), @(sizes[1]), @(sizes[2]), @(sizes[3]) ];
}
static NV2AMetalWritableProgram *
readonly_constant_program_from_source(id<MTLDevice> device, const char *path)
{
    if (!path)
        return nil;
    NSError *error = nil;
    NSString *source = [NSString stringWithContentsOfFile:@(path)
                                                 encoding:NSUTF8StringEncoding
                                                    error:&error];
    require(source != nil, error);
    id<MTL4Compiler> compiler =
        [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                    error:&error];
    require(compiler != nil, error);
    id<MTLLibrary> library = readonly_constant_library(compiler, source);
    NV2AMetalWritableProgram *program =
        [[NV2AMetalWritableProgram alloc] initWithDevice:device error:&error];
    require(program != nil, error);
    [program setValue:readonly_constant_pipeline(compiler, library,
                                                 @"nv2a_readonly_program")
               forKey:@"readonlyPipeline"];
    [program setValue:readonly_constant_pipeline(compiler, library,
                                                 @"nv2a_writable_program")
               forKey:@"pipeline"];
    return program;
}
static void readonly_constant_tokens(Token tokens[3], unsigned row,
                                     BOOL relative, unsigned swizzle)
{
    tokens[0] = token(1, 0, 96);
    source(&tokens[0], 0, 2, 0, 0xe4);
    destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
    unsigned last = 1;
    if (relative) {
        tokens[1] = token(13, 0, 96);
        tokens[1].word[1] |= 1u << 9;
        source(&tokens[1], 0, 2, 0, 0xe4);
        destination(&tokens[1], 0, 0, 0, 0, 8, 0);
        last = 2;
    }
    tokens[last] = token(1, 0, relative ? 96 : row);
    source(&tokens[last], 0, 3, 0, swizzle);
    destination(&tokens[last], 0x109, 15, 0, 0, 0, 0);
    tokens[last].word[3] |= relative ? 3 : 1;
}
static NV2AMetalWritableResult *
readonly_constant_run(NV2AMetalWritableProgram *program, Token *tokens,
                      unsigned length, NV2AMetalProgramUniforms *u,
                      id<MTLBuffer> input, unsigned first, unsigned count,
                      unsigned access, BOOL enabled, BOOL rasterize,
                      NSError **error)
{
    return [program executeTokens:tokens[0].word
                           length:length
                         uniforms:u
                  attributeBuffer:input
                            first:first
                            count:count
                           access:access
                      writeEnable:enabled
                        rasterize:rasterize
                            error:error];
}
static NSMutableArray<NSDictionary *> *readonly_constant_times;
static NSString *readonly_constant_timing_label;
static unsigned readonly_constant_timing_count;
static void (*readonly_constant_original_feedback)(id, SEL,
                                                   MTL4CommitFeedbackHandler);
static void readonly_constant_feedback_hook(id object, SEL selector,
                                            MTL4CommitFeedbackHandler original)
{
    NSString *label = readonly_constant_timing_label;
    unsigned count = readonly_constant_timing_count;
    readonly_constant_original_feedback(
        object, selector, ^(id<MTL4CommitFeedback> feedback) {
          @synchronized(readonly_constant_times) {
              [readonly_constant_times addObject:@{
                  @"label" : label,
                  @"vertices" : @(count),
                  @"GPUStartTime" : @(feedback.GPUStartTime),
                  @"GPUEndTime" : @(feedback.GPUEndTime),
                  @"error" : @(feedback.error != nil)
              }];
          }
          original(feedback);
        });
}
static NSArray *readonly_constant_benchmark(NV2AMetalWritableProgram *candidate,
                                            NV2AMetalWritableProgram *reference,
                                            id<MTLDevice> device)
{
    if (!reference)
        return @[];
    readonly_constant_times = [NSMutableArray new];
    Method method = class_getInstanceMethod(MTL4CommitOptions.class,
                                            @selector(addFeedbackHandler:));
    assert(method);
    readonly_constant_original_feedback = (void *)method_setImplementation(
        method, (IMP)readonly_constant_feedback_hook);
    const unsigned counts[] = { 64, 1024, 8192 };
    NV2AMetalProgramUniforms u = uniforms();
    Token tokens[7];
    writable_tokens(tokens, 104, 3, 15);
    for (unsigned c = 0; c < 3; c++) {
        unsigned count = counts[c];
        NV2AMetalProgramInput *input = calloc(count, sizeof(*input));
        assert(input);
        for (unsigned i = 0; i < count; i++)
            writable_input(&input[i], i);
        id<MTLBuffer> buffer =
            [device newBufferWithBytes:input
                                length:count * sizeof(*input)
                               options:MTLResourceStorageModeShared];
        free(input);
        assert(buffer);
        for (unsigned iteration = 0; iteration < 18; iteration++) {
            /* Alternate order to keep the same sustained device workload. */
            for (unsigned side = 0; side < 2; side++) {
                BOOL old = (iteration + side) % 2 == 0;
                readonly_constant_timing_label = old ? @"reference" : @"direct";
                readonly_constant_timing_count = count;
                NSError *error = nil;
                NV2AMetalWritableResult *r = readonly_constant_run(
                    old ? reference : candidate, tokens, 7, &u, buffer, 0,
                    count, 1, NO, NO, &error);
                require(r != nil, error);
                const NV2AMetalProgramOutput *raw = r.registers.contents;
                assert(!raw[count - 1].fault);
            }
        }
    }
    method_setImplementation(method, (IMP)readonly_constant_original_feedback);
    NSArray *times = [readonly_constant_times copy];
    assert(times.count == 108);
    for (NSDictionary *row in times)
        assert(![row[@"error"] boolValue] &&
               [row[@"GPUStartTime"] doubleValue] > 0 &&
               [row[@"GPUEndTime"] doubleValue] >=
                   [row[@"GPUStartTime"] doubleValue]);
    readonly_constant_timing_label = nil;
    readonly_constant_times = nil;
    return times;
}
static void readonly_constant_tests(NV2AMetalWritableProgram *candidate,
                                    NV2AMetalCommands *commands)
{
    NSArray *sizes = readonly_constant_sizes(commands);
    NV2AMetalWritableProgram *reference = readonly_constant_program_from_source(
        commands.device, getenv("XEMU_METAL4_READONLY_REFERENCE_SOURCE"));
    NV2AMetalWritableProgram *override = readonly_constant_program_from_source(
        commands.device, getenv("XEMU_METAL4_READONLY_CANDIDATE_SOURCE"));
    if (override)
        candidate = override;
    enum { First = 3, Count = 17, Total = First + Count + 5 };
    NV2AMetalProgramInput input[Total];
    for (unsigned i = 0; i < Total; i++) {
        writable_input(&input[i], i);
        input[i].attributes[0][0] = i + 1;
        input[i].attributes[0][3] = 1;
    }
    id<MTLBuffer> buffer =
        [commands.device newBufferWithBytes:input
                                     length:sizeof(input)
                                    options:MTLResourceStorageModeShared];
    assert(buffer);
    NV2AMetalProgramUniforms u = uniforms();
    const uint32_t bits[] = { 0,          0x80000000, 1,          0x80000001,
                              0x007fffff, 0x7f7fffff, 0xff7fffff, 0x7f800000,
                              0xff800000, 0x7fc00123, 0x7f800123 };
    for (unsigned row = 0; row < 192; row++)
        for (unsigned k = 0; k < 4; k++) {
            uint32_t word =
                bits[(row * 4 + k) % (sizeof(bits) / sizeof(bits[0]))];
            memcpy(&u.constants[row][k], &word, 4);
        }
    unsigned accepted = 0, rejected = 0, compared = 0, vertices = 0;
    for (unsigned enabled = 0; enabled < 2; enabled++)
        for (unsigned relative = 0; relative < 2; relative++)
            for (unsigned access = 0; access < 2; access++)
                for (unsigned row = 0; row < 192; row++) {
                    @autoreleasepool {
                        unsigned swizzle = row % 2 ? 0x1b : 0xe4;
                        Token tokens[3];
                        readonly_constant_tokens(tokens, row, relative,
                                                 swizzle);
                        for (unsigned i = 0; i < Total; i++)
                            input[i].attributes[1][0] =
                                i >= First && i < First + Count ?
                                    (float)row - 96 :
                                    1000;
                        memcpy(buffer.contents, input, sizeof(input));
                        NSError *error = nil, *referenceError = nil;
                        NV2AMetalWritableResult *r = readonly_constant_run(
                            candidate, tokens, relative ? 3 : 2, &u, buffer,
                            First, Count, access, enabled, row % 2, &error);
                        NV2AMetalWritableResult *old =
                            reference ? readonly_constant_run(
                                            reference, tokens, relative ? 3 : 2,
                                            &u, buffer, First, Count, access,
                                            enabled, row % 2, &referenceError) :
                                        nil;
                        BOOL allowed = access || row >= 96 ||
                                       (!relative && (row == 58 || row == 59));
                        if (!allowed) {
                            assert(!r && error &&
                                   [error.localizedDescription
                                       containsString:@"address fault"]);
                            if (reference)
                                assert(!old &&
                                       [referenceError.localizedDescription
                                           isEqualToString:
                                               error.localizedDescription]);
                            rejected++;
                        } else {
                            require(r != nil, error);
                            assert(!memcmp(r.constants.bytes, u.constants,
                                           sizeof(u.constants)));
                            const uint32_t *dirty = r.written.bytes;
                            for (unsigned i = 0; i < 192; i++)
                                assert(!dirty[i]);
                            const NV2AMetalProgramOutput *raw =
                                r.registers.contents;
                            for (unsigned v = 0; v < Count; v++) {
                                assert(!raw[v].fault);
                                assert(!memcmp(raw[v].registers[0],
                                               input[First + v].attributes[0],
                                               16));
                                for (unsigned k = 0; k < 4; k++) {
                                    unsigned lane = (swizzle >> (2 * k)) & 3;
                                    assert(!memcmp(&raw[v].registers[9][k],
                                                   &u.constants[row][lane], 4));
                                }
                                vertices++;
                            }
                            if (reference) {
                                require(old != nil, referenceError);
                                assert(!memcmp(
                                    r.registers.contents,
                                    old.registers.contents,
                                    Count * sizeof(NV2AMetalProgramOutput)));
                                assert(!memcmp(
                                    r.vertices.contents, old.vertices.contents,
                                    Count * sizeof(NV2AMetalVertex)));
                                assert(
                                    [r.constants isEqualToData:old.constants] &&
                                    [r.written isEqualToData:old.written]);
                            }
                            accepted++;
                        }
                        if (reference)
                            compared++;
                        assert(!memcmp(buffer.contents, input, sizeof(input)));
                    }
                }
    assert(accepted == 1156 && rejected == 380 && vertices == 19652);
    assert(!reference || compared == 1536);
    printf("Readonly direct constants: %u accepted/%u aperture faults, %u "
           "exact vertices, %u old-kernel comparisons PASS\n",
           accepted, rejected, vertices, compared);
    NSArray *times =
        readonly_constant_benchmark(candidate, reference, commands.device);
    const char *metrics = getenv("XEMU_METAL4_READONLY_METRICS_FILE");
    if (metrics) {
        NSError *error = nil;
        NSData *json =
            [NSJSONSerialization dataWithJSONObject:@{
                @"structure_sizes" : sizes,
                @"accepted" : @(accepted),
                @"rejected" : @(rejected),
                @"vertices" : @(vertices),
                @"reference_cases" : @(compared),
                @"GPU_timings" : times
            }
                                            options:NSJSONWritingPrettyPrinted
                                              error:&error];
        require(json != nil, error);
        require([json writeToFile:@(metrics)
                          options:NSDataWritingAtomic
                            error:&error],
                error);
    }
}
#endif
