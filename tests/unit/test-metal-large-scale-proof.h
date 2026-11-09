/* Large captured Float32 operands scaled back into the bounded IDX domain.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_LARGE_SCALE_PROOF_H
#define TEST_METAL_LARGE_SCALE_PROOF_H
#include <float.h>

typedef struct LargeScaleSample {
    uint32_t a, b;
    int32_t low, high;
    uint32_t proven;
} LargeScaleSample;
_Static_assert(sizeof(LargeScaleSample) == 20, "Large product MSL ABI");
_Static_assert(DBL_MANT_DIG >= 48, "Float32 products are exact in the oracle");

static unsigned large_scale_tokens(Token t[5], unsigned base, BOOL read,
                                   unsigned form)
{
    t[0] = token(NV2AMetalMACMov, 0, 96);
    source(t, 0, 2, 0, 0xe4);
    destination(t, 0x100, 15, 0, 0, 0, 0);
    unsigned n = 1;
    if (form == 2) {
        t[n] = token(NV2AMetalMACMov, 0, 100);
        source(t + n, 0, 3, 0, 0);
        destination(t + n++, 0, 0, 0, 4, 8, 0);
    }
    t[n] = token(NV2AMetalMACMul, 0, 100);
    source(t + n, 0, form == 2 ? 1 : 3, form == 2 ? 4 : 0,
           form == 1 ? 0x55 : 0);
    source(t + n, 1, 3, 0, form == 1 ? 0 : 0x55);
    if (form == 3)
        t[n].word[1] |= 1u << 8;
    destination(t + n++, 0x109, 15, 0, 2, 8, 0);
    t[n] = token(NV2AMetalMACArl, 0, 96);
    source(t + n, 0, 1, 2, 0);
    n++;
    if (read) {
        t[n] = token(NV2AMetalMACMov, 0, base);
        source(t + n, 0, 3, 0, 0xe4);
        destination(t + n, 0x103, 15, 0, 0, 0, 0);
        t[n++].word[3] |= 2;
    }
    t[n - 1].word[3] |= 1;
    return n;
}

/* Binary64 has enough significand and exponent bits for the exact product
 * of two normal Float32 inputs. No production range/bit helper is called. */
static BOOL large_scale_bounds(uint32_t a, uint32_t b, int *low, int *high)
{
    unsigned ae = (a >> 23) & 255, be = (b >> 23) & 255;
    if (!ae || !be) {
        *low = *high = 0;
        return YES;
    }
    if (ae == 255 || be == 255)
        return NO;
    float x, y;
    memcpy(&x, &a, 4);
    memcpy(&y, &b, 4);
    double product = (double)x * (double)y;
    double lo = floor(product), hi = ceil(product);
    if (lo < -0x1p24 || hi > 0x1p24)
        return NO;
    *low = (int)lo;
    *high = (int)hi;
    return YES;
}

static NSMutableData *large_scale_samples(void)
{
    NSError *error = nil;
    Token t[5];
    unsigned n = large_scale_tokens(t, 96, NO, 0);
    NV2AMetalValidatedProgram *program =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                   length:n
                                                    error:&error];
    require(program != nil, error);
    NV2AMetalProgramUniforms u = uniforms();
    NSMutableData *data = [NSMutableData new];
    const unsigned mantissas[] = {1, 0x123456, 0x7fffff};
    const int powers[] = {-150, -25, -1, 0, 1, 6, 24, 25, 30, 100};
    for (unsigned exponent = 151; exponent < 255; exponent++)
        for (unsigned m = 0; m < 3; m++)
            for (unsigned power = 0; power < 18; power++)
                for (unsigned k = 0; k < 3; k++)
                    for (unsigned sign = 0; sign < 4; sign++) {
                        @autoreleasepool {
                            LargeScaleSample sample = {0};
                            sample.a = exponent << 23 | mantissas[m] |
                                       (sign & 1) << 31;
                            if (power < 10) {
                                int e = 254 - (int)exponent + powers[power];
                                if (e < 1 || e > 254)
                                    continue;
                                sample.b = (unsigned)e << 23 | mantissas[k];
                            } else {
                                const uint32_t special[] = {
                                    0,          1,          0x007fffff,
                                    0x00800000, 0x3f800000, 0x7f800000,
                                    0x7fc12345, 0x7f800001};
                                sample.b = special[power - 10];
                            }
                            sample.b |= (sign >> 1) << 31;
                            sample.proven = large_scale_bounds(
                                sample.a, sample.b, &sample.low, &sample.high);
                            memcpy(u.constants[100], &sample.a, 4);
                            memcpy(u.constants[100] + 1, &sample.b, 4);
                            BOOL observed = [program
                                hasFaultFreeReadOnlyAccess:1
                                                 constants:u.constants[0]];
                            assert(observed == sample.proven);
                            [data appendBytes:&sample length:sizeof(sample)];
                        }
                    }
    return data;
}

static void large_scale_gpu_tests(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NSData *samples = large_scale_samples();
    NSUInteger count = samples.length / sizeof(LargeScaleSample);
    assert(count > 40000);
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    NSString *source = [@(readonly_constant_shader_source)
        stringByAppendingString:
            @"\nstruct LargeCase {uint a,b;int low,high;uint proven;};"
             "kernel void large_products(device const LargeCase *c "
             "[[buffer(0)]],"
             "device uint2 *out [[buffer(1)]],uint id "
             "[[thread_position_in_grid]]) {"
             "uint p=vp_multiply_rz(c[id].a,c[id].b);"
             "float address=floor(as_type<float>(p)+0.001f);"
             "out[id]=uint2(p,!isfinite(address)||address < -2147483648.0f||"
             "address>=2147483648.0f); }\n"];
    id<MTLLibrary> library = readonly_constant_library(compiler, source);
    id<MTLComputePipelineState> pipeline =
        readonly_constant_pipeline(compiler, library, @"large_products");
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:samples.bytes
                                     length:samples.length
                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:count * 8
                                     options:MTLResourceStorageModeShared];
    assert(input && output);
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 2;
    ad.initializeBindings = YES;
    id<MTL4ArgumentTable> table =
        [commands.device newArgumentTableWithDescriptor:ad error:&error];
    require(table != nil, error);
    require([commands beginWithError:&error] != nil, error);
    require([commands addResource:input error:&error] &&
                [commands addResource:output error:&error],
            error);
    [table setAddress:input.gpuAddress atIndex:0];
    [table setAddress:output.gpuAddress atIndex:1];
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder setComputePipelineState:pipeline];
    [encoder setArgumentTable:table];
    [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [encoder barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    const LargeScaleSample *cases = samples.bytes;
    const uint32_t *raw = output.contents;
    unsigned proven = 0;
    for (NSUInteger i = 0; i < count; i++)
        if (cases[i].proven) {
            float actual;
            memcpy(&actual, raw + i * 2, 4);
            assert(isfinite(actual) && actual >= cases[i].low &&
                   actual <= cases[i].high && !raw[i * 2 + 1]);
            proven++;
        }
    NV2AMetalWritableProgram *reference =
        [[SpecializedReadonlyReference alloc] initWithDevice:commands.device
                                                       error:&error];
    require(reference != nil, error);
    NV2AMetalProgramInput vertices[4];
    for (unsigned i = 0; i < 4; i++)
        writable_input(vertices + i, i);
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:vertices
                                     length:sizeof(vertices)
                                    options:MTLResourceStorageModeShared];
    assert(attributes);
    const uint32_t pairs[][2] = {
        {0x4b800001, 0x33800000}, {0x53800000, 0x2b800000},
        {0x71800000, 0x0d800000}, {0x7f7fffff, 0x00800000},
        {0x7f7fffff, 1},          {0x7f800000, 0},
        {0x4b800001, 0x3f800000}, {0x7fc12345, 0x3f800000}};
    unsigned before = constant_idx_pairs;
    unsigned beforeSafe = constant_idx_safe, beforeFaults = constant_idx_faults;
    for (unsigned p = 0; p < 8; p++)
        for (unsigned form = 0; form < 4; form++)
            for (unsigned read = 0; read < 2; read++)
                for (unsigned b = 0; b < 4; b++)
                    for (unsigned access = 0; access < 2; access++) {
                        NV2AMetalProgramUniforms u = uniforms();
                        memcpy(u.constants[100], pairs[p], 8);
                        unsigned base = (unsigned[]){0, 95, 96, 191}[b];
                        int low = 0, high = 0;
                        BOOL safe = large_scale_bounds(
                            pairs[p][0] ^ (form == 3 ? 0x80000000u : 0),
                            pairs[p][1], &low, &high);
                        safe &=
                            !read || ((int)base + low >= (access ? 0 : 96) &&
                                      (int)base + high < 192);
                        Token t[5];
                        unsigned n = large_scale_tokens(t, base, read, form);
                        constant_idx_pair(commands, reference, t, n, &u,
                                          attributes, access, safe, -1);
                    }
    printf("Large scale proof: %lu product certificates, %u admitted GPU "
           "intervals, %u compact/full pending/constant-window pairs PASS\n",
           (unsigned long)count, proven, constant_idx_pairs - before);
    constant_idx_pairs = before;
    constant_idx_safe = beforeSafe;
    constant_idx_faults = beforeFaults;
}
#endif
