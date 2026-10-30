/* Native unrolled Readonly XF versus general Metal4 interpreter.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_SPECIALIZED_READONLY_H
#define TEST_METAL_SPECIALIZED_READONLY_H
#import <objc/runtime.h>
@interface NV2AMetalWritableProgram (SpecializedReadonlyTest)
- (NSArray *)compileReadonlyProgram:(id)program error:(NSError **)error;
- (id<MTLComputePipelineState>)readonlyPipelineForProgram:(id)program
                                                  compact:(BOOL)compact
                                                  discard:(BOOL)discard;
@end
@interface SpecializedReadonlyReference : NV2AMetalWritableProgram
@property(nonatomic) NSUInteger generalDispatches;
@end
@implementation SpecializedReadonlyReference
- (id<MTLComputePipelineState>)readonlyPipelineForProgram:(id)program
                                                  compact:(BOOL)compact
                                                  discard:(BOOL)discard
{
    (void)program;
    _generalDispatches++;
    return [self valueForKey:discard ? @"readonlyRawPipeline" :
                             compact ? @"rasterPipeline" :
                                       @"readonlyPipeline"];
}
@end
@interface SpecializedMeasuredProgram : NV2AMetalWritableProgram
@property(nonatomic, strong) dispatch_semaphore_t gate, entered;
@property(nonatomic) BOOL fail;
@property(nonatomic) double compileMilliseconds;
@end
@implementation SpecializedMeasuredProgram
- (NSArray *)compileReadonlyProgram:(id)program error:(NSError **)error
{
    if (_entered)
        dispatch_semaphore_signal(_entered);
    if (_gate)
        assert(!dispatch_semaphore_wait(
            _gate, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)));
    if (_fail) {
        if (error)
            *error = [NSError errorWithDomain:@"specialization-test"
                                         code:1
                                     userInfo:nil];
        return nil;
    }
    double start = program_lru_clock();
    NSArray *result = [super compileReadonlyProgram:program error:error];
    _compileMilliseconds += program_lru_clock() - start;
    return result;
}
@end
static void specialized_wait(NV2AMetalWritableProgram *program)
{
    dispatch_queue_t queue = [program valueForKey:@"specializationQueue"];
    dispatch_sync(queue, ^{
                  });
    id entry = program_cache_entry(program);
    NSError *error = [entry valueForKey:@"specializationError"];
    require([[entry valueForKey:@"specializedPipelines"] count] == 3, error);
    assert(!program_lru_counter(program, @"specializationPending"));
}
static NV2AMetalWritableEncoding *
specialized_encode(NV2AMetalWritableProgram *program,
                   NV2AMetalCommands *commands, const Token *tokens,
                   NSUInteger length, const NV2AMetalProgramUniforms *u,
                   id<MTLBuffer> input, NSUInteger first, NSUInteger count,
                   unsigned access, BOOL rasterize, BOOL compact)
{
    NSError *error = nil;
    NV2AMetalWritableEncoding *e = [program encodeTokens:tokens[0].word
                                                  length:length
                                                uniforms:u
                                         attributeBuffer:input
                                                   first:first
                                                   count:count
                                                  access:access
                                             writeEnable:NO
                                               rasterize:rasterize
                                        compactRegisters:compact
                                                commands:commands
                                                   error:&error];
    require(e != nil, error);
    return e;
}
static void specialized_pair(
    NV2AMetalWritableProgram *native, NV2AMetalWritableProgram *reference,
    NV2AMetalCommands *commands, const Token *tokens, NSUInteger length,
    const NV2AMetalProgramUniforms *u, id<MTLBuffer> input, NSUInteger first,
    NSUInteger count, unsigned access, BOOL rasterize, BOOL compact)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalWritableEncoding *a =
        specialized_encode(native, commands, tokens, length, u, input, first,
                           count, access, rasterize, compact);
    NV2AMetalWritableEncoding *b =
        specialized_encode(reference, commands, tokens, length, u, input, first,
                           count, access, rasterize, compact);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    id<MTLBuffer> ar = [a valueForKey:@"raw"], br = [b valueForKey:@"raw"];
    id<MTLBuffer> av = [a valueForKey:@"vertices"],
                  bv = [b valueForKey:@"vertices"];
    assert(ar.length == br.length && av.length == bv.length);
    assert(!memcmp(ar.contents, br.contents,
                   compact ? sizeof(uint32_t) :
                             count * sizeof(NV2AMetalProgramOutput)));
    if (compact && !rasterize)
        assert(!av && !bv);
    else
        assert(
            !memcmp(av.contents, bv.contents, count * sizeof(NV2AMetalVertex)));
    NSError *ae = nil, *be = nil;
    NV2AMetalWritableResult *ra = [a resolveWithError:&ae],
                            *rb = [b resolveWithError:&be];
    assert(!!ra == !!rb);
    assert(((SpecializedReadonlyReference *)reference).generalDispatches &&
           !program_lru_counter(reference, @"specializationAttempts") &&
           !program_lru_counter(reference, @"specializedDispatches"));
    if (ra) {
        assert([ra.constants isEqual:rb.constants] &&
               [ra.written isEqual:rb.written]);
    } else {
        assert([ae.localizedDescription isEqual:be.localizedDescription]);
    }
}
static void specialized_warm(NV2AMetalWritableProgram *program,
                             NV2AMetalCommands *commands, const Token *tokens,
                             NSUInteger length, NV2AMetalProgramUniforms *u,
                             id<MTLBuffer> input)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    for (unsigned i = 0; i < 4; i++)
        specialized_encode(program, commands, tokens, length, u, input, 0, 1, 1,
                           YES, NO);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    specialized_wait(program);
}
static void specialized_op_tokens(Token tokens[6], unsigned mac, unsigned ilu,
                                  unsigned mask, unsigned temp,
                                  unsigned swizzle)
{
    for (unsigned i = 0; i < 6; i++)
        tokens[i] = token(1, 0, 96);
    source(&tokens[0], 0, 2, 0, 0xe4);
    destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
    tokens[1].word[1] |= 1u << 9;
    source(&tokens[1], 0, 2, 0, 0xe4);
    destination(&tokens[1], 0, 0, 0, 0, 15, 0);
    tokens[2].word[1] |= 2u << 9;
    source(&tokens[2], 0, 2, 0, 0xe4);
    destination(&tokens[2], 0, 0, 0, 1, 15, 0);
    tokens[3] = token(mac, ilu, 96);
    tokens[3].word[1] |= 3u << 9;
    source(&tokens[3], 0, 1, 0, swizzle);
    source(&tokens[3], 1, 3, 0, swizzle);
    source(&tokens[3], 2, 2, 0, swizzle);
    unsigned mux = ilu && ((mac + ilu) & 1);
    destination(&tokens[3], 0x103, mac == 13 && !mux ? 0 : mask, mux, temp,
                mask, mask);
    if ((mac + ilu) & 1)
        tokens[3].word[1] |= 1u << 8;
    if ((mac + ilu) & 2)
        tokens[3].word[2] |= 1u << 25;
    if ((mac + ilu) & 4)
        tokens[3].word[2] |= 1u << 10;
    source(&tokens[4], 0, 1, temp, 0xe4);
    destination(&tokens[4], 0x109, 15, 0, 0, 0, 0);
    source(&tokens[5], 0, 1, mac && ilu ? 1 : temp, 0xe4);
    destination(&tokens[5], 0x10a, 15, 0, 0, 0, 0);
    tokens[5].word[3] |= 1;
}
static void specialized_compilation_lifecycle(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    SpecializedMeasuredProgram *p =
        [[SpecializedMeasuredProgram alloc] initWithDevice:commands.device
                                                     error:&error];
    require(p != nil, error);
    p.gate = dispatch_semaphore_create(0);
    p.entered = dispatch_semaphore_create(0);
    NV2AMetalProgramInput inputValue;
    writable_input(&inputValue, 0);
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:&inputValue
                                     length:sizeof(inputValue)
                                    options:MTLResourceStorageModeShared];
    NV2AMetalProgramUniforms u = uniforms();
    __weak id first, second;
    id deferred;
    NSMutableArray *encodings = [NSMutableArray new];
    require([commands beginWithError:&error] != nil, error);
    @autoreleasepool {
        for (unsigned n = 0; n < 3; n++) {
            Token tokens[2];
            program_lru_tokens(tokens, 100 + n);
            for (unsigned call = 0; call < 4; call++)
                [encodings
                    addObject:specialized_encode(p, commands, tokens, 2, &u,
                                                 input, 0, 1, 1, YES, NO)];
            if (!n)
                first = program_cache_entry(p);
            else if (n == 1)
                second = program_cache_entry(p);
            else
                deferred = program_cache_entry(p);
        }
    }
    assert(!dispatch_semaphore_wait(
        p.entered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    assert(program_lru_counter(p, @"specializationPending") == 2 &&
           program_lru_counter(p, @"specializationAttempts") == 2 &&
           ![[deferred valueForKey:@"specializationQueued"] boolValue]);
    /* Queued jobs retain at most two evicted entries. GPU work finishes while
     * the compiler remains gated, including after their host cache entries have
     * been evicted.
     */
    NV2AMetalLRUCache *cache = [p valueForKey:@"programs"];
    for (unsigned cold = 0; cold < 65; cold++)
        @autoreleasepool {
            Token tokens[2];
            program_lru_tokens(tokens, cold);
            require([p programForTokens:tokens[0].word length:2
                                  error:&error] != nil,
                    error);
            program_lru_tokens(tokens, 102);
            require([p programForTokens:tokens[0].word length:2
                                  error:&error] == deferred,
                    error);
        }
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    for (NV2AMetalWritableEncoding *e in encodings)
        require([e resolveWithError:&error] != nil, error);
    @autoreleasepool {
        assert(first && second && cache.count == 64);
    }
    dispatch_semaphore_signal(p.gate);
    dispatch_semaphore_signal(p.gate);
    dispatch_sync((dispatch_queue_t)[p valueForKey:@"specializationQueue"], ^{
                  });
    assert(!program_lru_counter(p, @"specializationPending") &&
           program_lru_counter(p, @"specializationSuccesses") == 2);
    @autoreleasepool {
        assert(!first && !second);
    }
    /* A task deferred by pressure is eligible on the next regular call. */
    Token tokens[2];
    program_lru_tokens(tokens, 102);
    require([commands beginWithError:&error] != nil, error);
    specialized_encode(p, commands, tokens, 2, &u, input, 0, 1, 1, YES, NO);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    dispatch_semaphore_signal(p.gate);
    specialized_wait(p);
    assert(program_lru_counter(p, @"specializationSuccesses") == 3);
    /* A compiler failure is local to its optional specialization. The
     * validated general Metal4 interpreter keeps serving this immutable key. */
    SpecializedMeasuredProgram *failed =
        [[SpecializedMeasuredProgram alloc] initWithDevice:commands.device
                                                     error:&error];
    failed.fail = YES;
    require([commands beginWithError:&error] != nil, error);
    for (unsigned call = 0; call < 4; call++)
        specialized_encode(failed, commands, tokens, 2, &u, input, 0, 1, 1, YES,
                           NO);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    dispatch_sync((dispatch_queue_t)[failed valueForKey:@"specializationQueue"],
                  ^{
                  });
    assert(program_lru_counter(failed, @"specializationFailures") == 1 &&
           !program_lru_counter(failed, @"specializationPending"));
    NV2AMetalWritableProgram *reference =
        [[SpecializedReadonlyReference alloc] initWithDevice:commands.device
                                                       error:&error];
    require(reference != nil, error);
    for (unsigned call = 0; call < 8; call++)
        specialized_pair(failed, reference, commands, tokens, 2, &u, input, 0,
                         1, 1, YES, NO);
    assert(program_lru_counter(failed, @"specializationAttempts") == 1 &&
           !program_lru_counter(failed, @"specializedDispatches"));
    puts("Specialized compile lifecycle:two-job bound,third deferred then "
         "retried;GPU completes behind gated compiler,evicted entries survive "
         "jobs and release afterward;injected compile failure serves eight "
         "exact general-GPU pairs without retry flood PASS");
}
static void (*specialized_original_feedback)(id, SEL,
                                             MTL4CommitFeedbackHandler);
static double specialized_gpu_seconds;
static void specialized_feedback(id owner, SEL selector,
                                 MTL4CommitFeedbackHandler handler)
{
    specialized_original_feedback(owner, selector, ^(id<MTL4CommitFeedback> f) {
      specialized_gpu_seconds = f.GPUEndTime - f.GPUStartTime;
      handler(f);
    });
}
static void specialized_inflight_lifetime(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalProgramInput inputValue;
    writable_input(&inputValue, 0);
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:&inputValue
                                     length:sizeof(inputValue)
                                    options:MTLResourceStorageModeShared];
    NV2AMetalProgramUniforms u = uniforms();
    Token tokens[2];
    program_lru_tokens(tokens, 104);
    NV2AMetalWritableEncoding *encoded;
    __weak id<MTLComputePipelineState> survivor;
    @autoreleasepool {
        NV2AMetalWritableProgram *p =
            [[NV2AMetalWritableProgram alloc] initWithDevice:commands.device
                                                       error:&error];
        require(p != nil, error);
        specialized_warm(p, commands, tokens, 2, &u, input);
        require([commands beginWithError:&error] != nil, error);
        encoded = specialized_encode(p, commands, tokens, 2, &u, input, 0, 1, 1,
                                     YES, NO);
        NSArray *pipelines =
            [program_cache_entry(p) valueForKey:@"specializedPipelines"];
        survivor = pipelines[0];
        NV2AMetalLRUCache *cache = [p valueForKey:@"programs"];
        [cache removeAllObjects];
        p = nil;
    }
    @autoreleasepool {
        assert(survivor);
    }
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    NV2AMetalWritableResult *result = [encoded resolveWithError:&error];
    require(result != nil, error);
    const NV2AMetalProgramOutput *raw = result.registers.contents;
    assert(!memcmp(raw->registers[0], inputValue.attributes[0], 16) &&
           !memcmp(raw->registers[3], u.constants[104], 16));
    puts("Specialized Readonly lifetime:queued native pipeline survives cache "
         "clear and owner destruction;GPU raw output and feedback exact PASS");
}
static void specialized_benchmark(NV2AMetalWritableProgram *native,
                                  NV2AMetalWritableProgram *reference,
                                  NV2AMetalCommands *commands)
{
    const NSUInteger count = 8192;
    NSMutableData *data =
        [NSMutableData dataWithLength:count * sizeof(NV2AMetalProgramInput)];
    NV2AMetalProgramInput *inputs = data.mutableBytes;
    for (unsigned v = 0; v < count; v++) {
        writable_input(&inputs[v], v);
        inputs[v].attributes[0][3] = 1;
        for (unsigned k = 0; k < 4; k++)
            inputs[v].attributes[3][k] = (v % 17 + k + 1) / 32.f;
    }
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:data.bytes
                                     length:data.length
                                    options:MTLResourceStorageModeShared];
    Token tokens[136];
    for (unsigned i = 0; i < 136; i++)
        tokens[i] = token(4, 0, 96);
    tokens[0] = token(1, 0, 96);
    source(&tokens[0], 0, 2, 0, 0xe4);
    destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
    tokens[1] = token(1, 0, 96);
    tokens[1].word[1] |= 3u << 9;
    source(&tokens[1], 0, 2, 0, 0xe4);
    destination(&tokens[1], 0, 0, 0, 0, 15, 0);
    for (unsigned i = 2; i < 135; i++) {
        tokens[i].word[1] |= 3u << 9;
        source(&tokens[i], 0, 1, 0, 0xe4);
        source(&tokens[i], 1, 3, 0, 0xe4);
        source(&tokens[i], 2, 2, 0, 0xe4);
        destination(&tokens[i], 0, 0, 0, 0, 15, 0);
    }
    tokens[135] = token(1, 0, 96);
    source(&tokens[135], 0, 1, 0, 0xe4);
    destination(&tokens[135], 0x103, 15, 0, 0, 0, 0);
    tokens[135].word[3] |= 1;
    NV2AMetalProgramUniforms u = uniforms();
    for (unsigned k = 0; k < 4; k++)
        u.constants[96][k] = .25f;
    specialized_warm(native, commands, tokens, 136, &u, input);
    Method feedback = class_getInstanceMethod(MTL4CommitOptions.class,
                                              @selector(addFeedbackHandler:));
    specialized_original_feedback =
        (void *)method_setImplementation(feedback, (IMP)specialized_feedback);
    double times[2][9];
    NSError *error = nil;
    for (unsigned trial = 0; trial < 11; trial++) {
        NV2AMetalWritableResult *results[2];
        for (unsigned order = 0; order < 2; order++) {
            unsigned mode = (trial + order) & 1;
            require([commands beginWithError:&error] != nil, error);
            NV2AMetalWritableEncoding *e =
                specialized_encode(mode ? native : reference, commands, tokens,
                                   136, &u, input, 0, count, 1, YES, YES);
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
            results[mode] = [e resolveWithError:&error];
            require(results[mode] != nil, error);
            assert(specialized_gpu_seconds > 0);
            if (trial >= 2)
                times[mode][trial - 2] = specialized_gpu_seconds;
        }
        assert(!memcmp(results[0].vertices.contents,
                       results[1].vertices.contents,
                       count * sizeof(NV2AMetalVertex)) &&
               [results[0].constants isEqual:results[1].constants] &&
               [results[0].written isEqual:results[1].written]);
    }
    method_setImplementation(feedback, (IMP)specialized_original_feedback);
    for (unsigned mode = 0; mode < 2; mode++)
        qsort(times[mode], 9, sizeof(double), program_lru_compare);
    id entry = program_cache_entry(native);
    NSArray *pipelines = [entry valueForKey:@"specializedPipelines"];
    id<MTLComputePipelineState> specialized = pipelines[1];
    id<MTLComputePipelineState> general =
        [reference valueForKey:@"rasterPipeline"];
    printf("Specialized Readonly benchmark:136 slots/8192 vertices,11 exact "
           "pairs,2 warmups/9 alternating samples;GPU median native/general "
           "%.6f/%.6f ms;worker compile elapsed total %.3f ms;SIMD "
           "width%lu/%lu,max threads%lu/%lu,static threadgroup bytes%lu/%lu "
           "(no register/spill count)\n",
           times[1][4] * 1000, times[0][4] * 1000,
           ((SpecializedMeasuredProgram *)native).compileMilliseconds,
           (unsigned long)specialized.threadExecutionWidth,
           (unsigned long)general.threadExecutionWidth,
           (unsigned long)specialized.maxTotalThreadsPerThreadgroup,
           (unsigned long)general.maxTotalThreadsPerThreadgroup,
           (unsigned long)specialized.staticThreadgroupMemoryLength,
           (unsigned long)general.staticThreadgroupMemoryLength);
}

static void specialized_readonly_tests(NV2AMetalCommands *commands)
{
    specialized_compilation_lifecycle(commands);
    NSError *error = nil;
    NV2AMetalWritableProgram *native =
        [[SpecializedMeasuredProgram alloc] initWithDevice:commands.device
                                                     error:&error];
    require(native != nil, error);
    NV2AMetalWritableProgram *reference =
        [[SpecializedReadonlyReference alloc] initWithDevice:commands.device
                                                       error:&error];
    require(reference != nil, error);
    NV2AMetalProgramInput inputs[67];
    for (unsigned i = 0; i < 67; i++)
        writable_input(&inputs[i], i);
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:inputs
                                     length:sizeof(inputs)
                                    options:MTLResourceStorageModeShared];
    NV2AMetalProgramUniforms u = uniforms();
    Token tokens[7];
    writable_tokens(tokens, 96, 3, 15);
    specialized_warm(native, commands, tokens, 7, &u, input);
    for (unsigned compact = 0; compact < 2; compact++)
        for (unsigned rasterize = 0; rasterize < 2; rasterize++)
            for (unsigned access = 0; access < 2; access++)
                specialized_pair(native, reference, commands, tokens, 7, &u,
                                 input, 3, 64, access, rasterize, compact);
    assert(program_lru_counter(native, @"specializedDispatches") == 8);
    const uint32_t bits[] = { 0,          0x80000000, 1,          0x80000001,
                              0x007fffff, 0x00800000, 0x3f800001, 0x3f7fffff,
                              0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000,
                              0x7fc00123, 0x7f800123, 0x3f000000, 0xbf800000,
                              0x49800000, 0xcf000000 };
    for (unsigned v = 0; v < 67; v++)
        for (unsigned a = 1; a < 16; a++)
            for (unsigned k = 0; k < 4; k++) {
                uint32_t value =
                    bits[(v + a * 3 + k) % (sizeof(bits) / sizeof(*bits))];
                memcpy(&inputs[v].attributes[a][k], &value, 4);
            }
    memcpy(input.contents, inputs, sizeof(inputs));
    unsigned pairs = 8, programs = 1;
    for (unsigned mac = 0; mac <= 13; mac++)
        for (unsigned ilu = 0; ilu <= 7; ilu++) {
            Token op[6];
            specialized_op_tokens(op, mac, ilu, 15, ((mac + ilu) & 1) ? 1 : 12,
                                  (mac & 1) ? 0x1b : 0xe4);
            specialized_warm(native, commands, op, 6, &u, input);
            programs++;
            for (unsigned compact = 0; compact < 2; compact++)
                for (unsigned rasterize = 0; rasterize < 2; rasterize++)
                    for (unsigned access = 0; access < 2; access++) {
                        uint32_t words[4];
                        for (unsigned k = 0; k < 4; k++)
                            words[k] = bits[(mac + ilu + access + k) %
                                            (sizeof(bits) / sizeof(*bits))];
                        memcpy(u.constants[96], words, sizeof(words));
                        specialized_pair(native, reference, commands, op, 6, &u,
                                         input, 3, 64, access, rasterize,
                                         compact);
                        pairs++;
                    }
        }
    for (unsigned mux = 0; mux < 2; mux++)
        for (unsigned mask = 0; mask < 16; mask++) {
            Token fog[6];
            specialized_op_tokens(fog, 1, 1, mask, 12, mux ? 0xff : 0x00);
            destination(&fog[3], 0x105, mask, mux, 12, mask, mask);
            specialized_warm(native, commands, fog, 6, &u, input);
            programs++;
            u.fog_enable = 1;
            u.fog_mode = (unsigned[]){ 0, 1, 3, 4, 5, 7 }[mask % 6];
            u.fog[0] = .25f;
            u.fog[1] = -.5f;
            u.point_programmed = mask & 1;
            for (unsigned compact = 0; compact < 2; compact++)
                for (unsigned rasterize = 0; rasterize < 2; rasterize++)
                    for (unsigned access = 0; access < 2; access++) {
                        specialized_pair(native, reference, commands, fog, 6,
                                         &u, input, 3, 64, access, rasterize,
                                         compact);
                        pairs++;
                    }
        }
    const unsigned rows[] = { 0, 58, 59, 95, 96, 191 };
    for (unsigned mode = 0; mode < 7; mode++) {
        Token address[3];
        BOOL relative = mode == 6;
        readonly_constant_tokens(address, relative ? 96 : rows[mode], relative,
                                 0xe4);
        unsigned length = relative ? 3 : 2;
        specialized_warm(native, commands, address, length, &u, input);
        programs++;
        for (unsigned compact = 0; compact < 2; compact++)
            for (unsigned rasterize = 0; rasterize < 2; rasterize++)
                for (unsigned access = 0; access < 2; access++) {
                    specialized_pair(native, reference, commands, address,
                                     length, &u, input, 3, 64, access,
                                     rasterize, compact);
                    pairs++;
                }
    }
    assert(program_lru_counter(native, @"specializationSuccesses") ==
               programs &&
           !program_lru_counter(native, @"specializationFailures") &&
           program_lru_counter(native, @"specializedDispatches") == pairs);
    printf(
        "Specialized Readonly opcode matrix:%u compiled programs/%u "
        "exact64-vertex pairs;all14 MAC x8 "
        "ILU,USER/FULL,full/compact,raw/raster,paired "
        "R1/R12,NaN/Inf/zero/denormal input and changing live constants PASS\n",
        programs, pairs);
    puts("Specialized Readonly extra matrix:all16 Fog masks x2 output "
         "muxes,static USER apertures and dynamic ARL/faults,live Fog/point "
         "modes included PASS");
    NV2AMetalLRUCache *cache = [native valueForKey:@"programs"];
    assert(cache.count == 64);
    NSUInteger nativePipelines = 0;
    for (id node in [[cache valueForKey:@"entries"] allValues])
        nativePipelines += [[[node valueForKey:@"object"]
            valueForKey:@"specializedPipelines"] count];
    assert(nativePipelines == 192 &&
           !program_lru_counter(native, @"specializationPending"));
    puts("Specialized Readonly cache:64 current program entries/192 ready "
         "pipeline objects after152 compiled programs;no pending jobs PASS");
    specialized_benchmark(native, reference, commands);
    specialized_inflight_lifetime(commands);
}
#endif
