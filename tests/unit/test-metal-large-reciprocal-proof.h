/* Large captured reciprocal inputs versus the native Kelvin arithmetic.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_LARGE_RECIPROCAL_PROOF_H
#define TEST_METAL_LARGE_RECIPROCAL_PROOF_H

static unsigned large_reciprocal_tokens(Token t[7], unsigned opcode,
                                        unsigned form, unsigned base)
{
    t[0] = token(NV2AMetalMACMov, 0, 96);
    source(t, 0, 2, 0, 0xe4);
    destination(t, 0x100, 15, 0, 0, 0, 0);
    unsigned n = 1;
    if (form == 1) {
        t[n] = token(NV2AMetalMACMov, 0, 100);
        source(t + n, 0, 3, 0, 0);
        destination(t + n++, 0, 0, 0, 4, 8, 0);
    } else if (form == 2) {
        t[n] = token(NV2AMetalMACSlt, 0, 96);
        t[n].word[1] |= 1u << 9;
        source(t + n, 0, 2, 0, 0);
        source(t + n, 1, 1, 0, 0);
        destination(t + n++, 0, 0, 0, 2, 8, 0);
        t[n] = token(NV2AMetalMACArl, 0, 96);
        source(t + n++, 0, 1, 2, 0);
    }
    t[n] = token(0, opcode, 100);
    source(t + n, 2, form == 1 ? 1 : 3, form == 1 ? 4 : 0, 0);
    destination(t + n, 0x109, 15, 1, 2, 0, 8);
    if (form == 2)
        t[n].word[3] |= 2;
    n++;
    t[n] = token(NV2AMetalMACArl, 0, 96);
    source(t + n++, 0, 1, 2, 0);
    t[n] = token(NV2AMetalMACMov, 0, base);
    source(t + n, 0, 3, 0, 0xe4);
    destination(t + n, 0x103, 15, 0, 0, 0, 0);
    t[n++].word[3] |= 3;
    return n;
}

static void large_reciprocal_gpu_tests(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalValidatedProgram *programs[3];
    for (unsigned op = 0; op < 3; op++) {
        Token t[7];
        unsigned n = large_reciprocal_tokens(t, NV2AMetalILURcp + op, 0, 160);
        programs[op] =
            [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                       length:n
                                                        error:&error];
        require(programs[op] != nil, error);
    }
    NSMutableData *data = [NSMutableData new];
    NV2AMetalProgramUniforms u = uniforms();
    for (unsigned exponent = 151; exponent < 255; exponent++)
        for (unsigned seam = 0; seam <= 128; seam++)
            for (int delta = -1; delta <= 1; delta++) {
                int mantissa = (int)(seam << 16) + delta;
                if (mantissa < 0 || mantissa > 0x7fffff)
                    continue;
                for (unsigned sign = 0; sign < 2; sign++) {
                    @autoreleasepool {
                        uint32_t bits =
                            exponent << 23 | (unsigned)mantissa | sign << 31;
                        memcpy(u.constants[100], &bits, 4);
                        for (unsigned op = 0; op < 3; op++)
                            assert([programs[op]
                                hasFaultFreeReadOnlyAccess:0
                                                 constants:u.constants[0]]);
                        [data appendBytes:&bits length:4];
                    }
                }
            }
    NSUInteger count = data.length / 4;
    assert(count == 79872);
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    require(compiler != nil, error);
    NSString *source = [@(readonly_constant_shader_source)
        stringByAppendingString:
            @"\nkernel void large_reciprocals(device const uint *c "
            @"[[buffer(0)]],"
             "device uint *out [[buffer(1)]],uint id "
             "[[thread_position_in_grid]]){"
             "uint v[3]={vp_rcp_bits(c[id],false),vp_rcp_bits(c[id],true),"
             "vp_rsq_bits(c[id])};for(uint op=0;op<3;op++){"
             "float f=as_type<float>(v[op]);float a=floor(f+0.001f);"
             "out[id*3+op]=!isfinite(f)||abs(f)>1||a < -1||a>1||"
             "(op==2&&f<0);}}\n"];
    id<MTLLibrary> library = readonly_constant_library(compiler, source);
    id<MTLComputePipelineState> pipeline =
        readonly_constant_pipeline(compiler, library, @"large_reciprocals");
    id<MTLBuffer> input =
        [commands.device newBufferWithBytes:data.bytes
                                     length:data.length
                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:count * 12
                                     options:MTLResourceStorageModeShared];
    assert(input && output);
    MTL4ArgumentTableDescriptor *descriptor = [MTL4ArgumentTableDescriptor new];
    descriptor.maxBufferBindCount = 2;
    id<MTL4ArgumentTable> table =
        [commands.device newArgumentTableWithDescriptor:descriptor
                                                  error:&error];
    require(table != nil, error);
    [table setAddress:input.gpuAddress atIndex:0];
    [table setAddress:output.gpuAddress atIndex:1];
    require([commands beginWithError:&error] &&
                [commands addResource:input error:&error] &&
                [commands addResource:output error:&error] &&
                [commands keepAlive:table error:&error] &&
                [commands keepAlive:pipeline error:&error],
            error);
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
    const uint32_t *results = output.contents;
    for (NSUInteger i = 0; i < count * 3; i++)
        assert(results[i] == 0);

    NV2AMetalWritableProgram *reference =
        [[SpecializedReadonlyReference alloc] initWithDevice:commands.device
                                                       error:&error];
    require(reference != nil, error);
    NV2AMetalProgramInput vertices[4];
    for (unsigned i = 0; i < 4; i++) {
        writable_input(vertices + i, i);
        vertices[i].attributes[1][0] = i & 1 ? 1 : -1;
    }
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:vertices
                                     length:sizeof(vertices)
                                    options:MTLResourceStorageModeShared];
    assert(attributes);
    const uint32_t values[] = {0x4b800001, 0xcb800001, 0x71800000, 0xf1800000,
                               0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000,
                               0x7fc12345, 0xff800001};
    unsigned before = constant_idx_pairs, beforeSafe = constant_idx_safe,
             beforeFaults = constant_idx_faults;
    for (unsigned v = 0; v < 10; v++)
        for (unsigned op = 0; op < 3; op++)
            for (unsigned form = 0; form < 3; form++)
                for (unsigned b = 0; b < 4; b++)
                    for (unsigned access = 0; access < 2; access++) {
                        NV2AMetalProgramUniforms constants = uniforms();
                        memcpy(constants.constants[100], values + v, 4);
                        memcpy(constants.constants[101], values + v, 4);
                        unsigned base = (unsigned[]){0, 96, 160, 191}[b];
                        BOOL finite = v < 6;
                        /* Large exact inputs retain a conservative [-1,1]
                         * reciprocal range; RSQ's lower endpoint is zero. */
                        BOOL safe = finite && base < 191 &&
                                    (op == 2 ? (access || base >= 96)
                                             : base >= (access ? 1u : 97u));
                        Token t[7];
                        unsigned n = large_reciprocal_tokens(
                            t, NV2AMetalILURcp + op, form, base);
                        constant_idx_pair(commands, reference, t, n, &constants,
                                          attributes, access, safe, -1);
                    }
    printf(
        "Large reciprocal proof: %lu native RCP/RCC/RSQ interval checks, "
        "%u compact/full pairs/%u admitted, all large finite exponents, "
        "LUT seams/signs, MOV/relative rows, NaN/Inf/aperture controls PASS\n",
        (unsigned long)count * 3, constant_idx_pairs - before,
        constant_idx_safe - beforeSafe);
    constant_idx_pairs = before;
    constant_idx_safe = beforeSafe;
    constant_idx_faults = beforeFaults;
}
#endif
