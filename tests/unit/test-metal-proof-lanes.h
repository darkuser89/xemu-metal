/* Numerical proof dependencies must not discard GPU operands or outputs.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_PROOF_LANES_H
#define TEST_METAL_PROOF_LANES_H
static void proof_lanes_tokens(Token t[8], unsigned relativeBase)
{
    t[0] = token(NV2AMetalMACMov, 0, 96);
    source(&t[0], 0, 2, 0, 0xe4);
    destination(&t[0], 0x100, 15, 0, 0, 0, 0);
    t[1] = token(NV2AMetalMACMov, 0, 96);
    t[1].word[1] |= 3u << 9;
    source(&t[1], 0, 2, 0, 0xe4);
    destination(&t[1], 0, 0, 0, 5, 15, 0);
    t[2] = token(NV2AMetalMACAdd, 0, 100);
    source(&t[2], 0, 1, 5, 0xe4);
    source(&t[2], 2, 3, 0, 0xe4);
    destination(&t[2], 0x103, 15, 0, 6, 15, 0);
    t[3] = token(NV2AMetalMACMov, 0, 101);
    source(&t[3], 0, 3, 0, 0xe4);
    destination(&t[3], 0, 0, 0, 9, 15, 0);
    t[4] = token(NV2AMetalMACMov, 0, 102);
    source(&t[4], 0, 3, 0, 0xe4);
    destination(&t[4], 0, 0, 0, 6, 8, 0);
    t[5] = token(NV2AMetalMACArl, 0, 96);
    source(&t[5], 0, 1, 6, 0x55);
    t[6] = token(NV2AMetalMACMov, 0, relativeBase);
    source(&t[6], 0, 3, 0, 0xe4);
    destination(&t[6], 0x104, 15, 0, 0, 0, 0);
    t[6].word[3] |= 2;
    t[7] = token(NV2AMetalMACArl, 0, 103);
    source(&t[7], 0, 3, 0, 0);
    t[7].word[3] |= 1;
}

static void proof_lane_cache_tests(void)
{
    NSError *error = nil;
    Token t[8];
    proof_lanes_tokens(t, 96);
    NV2AMetalValidatedProgram *program =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                   length:8
                                                    error:&error];
    require(program != nil, error);
    assert(program.readAttributes == ((1u << 0) | (1u << 3)));
    NV2AMetalProgramUniforms u = uniforms();
    u.constants[100][1] = .25f;
    u.constants[103][0] = 0;
    NV2AMetalFetchUniforms fetch = {0};
    fetch.attributes[3].inline_value[1] = .25f;
    assert([program hasFaultFreeReadOnlyAccess:0
                                     constants:u.constants[0]
                                sourceUniforms:&fetch]);
    NSData *key = [program valueForKey:@"fetchProofInputs"];
    NSData *copies = [program valueForKey:@"proofConstantCopies"];
    assert(copies.length ==
           8); /* Two isolated numerical constant components. */
    for (unsigned epoch = 0; epoch < 32; epoch++) {
        for (unsigned row = 0; row < 192; row++)
            for (unsigned lane = 0; lane < 4; lane++)
                if (!((row == 100 && lane == 1) || (row == 103 && lane == 0)))
                    u.constants[row][lane] = epoch + row + lane;
        for (unsigned attribute = 0; attribute < 16; attribute++)
            for (unsigned lane = 0; lane < 4; lane++)
                if (!(attribute == 3 && lane == 1))
                    memcpy(&fetch.attributes[attribute].inline_value[lane],
                           &(uint32_t){0x7fc12345}, 4);
        for (unsigned access = 0; access < 2; access++) {
            assert([program hasFaultFreeReadOnlyAccess:access
                                             constants:u.constants[0]
                                        sourceUniforms:&fetch]);
            assert([program valueForKey:@"fetchProofInputs"] == key);
        }
    }
    u.constants[100][1] = 128;
    assert(![program hasFaultFreeReadOnlyAccess:0
                                      constants:u.constants[0]
                                 sourceUniforms:&fetch] &&
           [program valueForKey:@"fetchProofInputs"] != key);
    key = [program valueForKey:@"fetchProofInputs"];
    u.constants[101][0] = -128;
    assert(![program hasFaultFreeReadOnlyAccess:0
                                      constants:u.constants[0]
                                 sourceUniforms:&fetch] &&
           [program valueForKey:@"fetchProofInputs"] == key);
    u.constants[100][1] = .25f;
    fetch.attributes[3].inline_value[1] = NAN;
    assert(![program hasFaultFreeReadOnlyAccess:0
                                      constants:u.constants[0]
                                 sourceUniforms:&fetch]);
    fetch.attributes[3].inline_value[1] = .25f;
    u.constants[103][0] = NAN;
    assert(![program
        hasFaultFreeReadOnlyAccess:0
                         constants:u.constants[0]
                    sourceUniforms:&fetch]); /* Unused ARL can still fault. */
    u.constants[103][0] = 0;
    fetch.attributes[3].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
    fetch.attributes[3].count = 4;
    assert(![program hasFaultFreeReadOnlyAccess:0
                                      constants:u.constants[0]
                                 sourceUniforms:&fetch]);
    fetch.attributes[3].count = 0;
    proof_lanes_tokens(t, 95);
    NV2AMetalValidatedProgram *aperture =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                   length:8
                                                    error:&error];
    require(aperture != nil, error);
    assert(![aperture hasFaultFreeReadOnlyAccess:0
                                       constants:u.constants[0]
                                  sourceUniforms:&fetch] &&
           [aperture hasFaultFreeReadOnlyAccess:1
                                      constants:u.constants[0]
                                 sourceUniforms:&fetch]);
    Token position = token(NV2AMetalMACMov, 0, 96);
    source(&position, 0, 2, 0, 0xe4);
    destination(&position, 0x100, 15, 0, 0, 0, 0);
    position.word[3] |= 1;
    NV2AMetalValidatedProgram *staticProgram =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:position.word
                                                   length:1
                                                    error:&error];
    require(staticProgram != nil, error);
    assert([staticProgram hasFaultFreeReadOnlyAccess:0] &&
           ![staticProgram valueForKey:@"proofPlan"] &&
           ![staticProgram valueForKey:@"proofConstantCopies"]);
    puts("Proof lane cache:32 changed color epochs reuse one source key;"
         "required constant/attribute/format changes invalidate it;"
         "partial temporary writes,unused ARL and unused numerical operands'"
         "apertures preserved,all GPU attributes retained PASS (CPU only)");
}

static void proof_lane_gpu_tests(NV2AMetalCommands *commands,
                                 NV2AMetalWritableProgram *executor)
{
    NSError *error = nil;
    NV2AMetalVertexFetch *fetch =
        [[NV2AMetalVertexFetch alloc] initWithDevice:commands.device
                                               error:&error];
    require(fetch != nil, error);
    unsigned cases = 0;
    NSData *first = nil;
    for (unsigned mode = 0; mode < 6; mode++)
        for (unsigned access = 0; access < 2; access++) {
            Token t[8];
            proof_lanes_tokens(t, mode == 3 ? 95 : 96);
            NV2AMetalValidatedProgram *program =
                [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                           length:8
                                                            error:&error];
            require(program != nil, error);
            NV2AMetalProgramUniforms u = uniforms();
            memset(u.constants[100], 0, 16);
            u.constants[100][1] = mode == 4 ? 128 : .25f;
            u.constants[103][0] = mode == 2 ? NAN : 0;
            NV2AMetalAttributeSource sources[16] = {0};
            for (unsigned attribute = 0; attribute < 16; attribute++)
                sources[attribute].inline_value[3] = 1;
            sources[3].inline_value[1] = mode == 5 ? NAN : .25f;
            if (mode == 1) {
                u.constants[100][0] = .5f;
                u.constants[100][2] = NAN;
                memset(u.constants[101], 0xff, 16);
                memset(u.constants[102], 0xff, 16);
                sources[3].inline_value[0] = .3f;
                sources[3].inline_value[2] = .6f;
            }
            BOOL valid = mode < 2 || (mode == 3 && access);
            require([commands beginWithError:&error] != nil, error);
            NV2AMetalFetchResult *attributes = [fetch encodeSources:sources
                                                              count:1
                                                        firstVertex:0
                                                            indices:nil
                                                        indexOffset:0
                                                          indexSize:0
                                                      currentVertex:NSNotFound
                                                           commands:commands
                                                              error:&error];
            require(attributes != nil, error);
            NV2AMetalWritableEncoding *a =
                [executor encodeProgram:program
                               uniforms:&u
                        attributeBuffer:attributes.attributes
                                  first:0
                                  count:1
                                 access:access
                            writeEnable:NO
                              rasterize:YES
                       compactRegisters:YES
                         attributeFetch:attributes
                               commands:commands
                                  error:&error];
            require(a != nil, error);
            NSData *sourceKey = [program valueForKey:@"fetchProofInputs"];
            assert(sourceKey.length == 4096);
            /* A separate constants-only query must not replace the source
             * scope's known YES/NO before this genuinely warm GPU encode. */
            (void)[program hasFaultFreeReadOnlyAccess:access
                                            constants:u.constants[0]];
            assert([program valueForKey:@"fetchProofInputs"] == sourceKey);
            NV2AMetalWritableEncoding *warm =
                [executor encodeProgram:program
                               uniforms:&u
                        attributeBuffer:attributes.attributes
                                  first:0
                                  count:1
                                 access:access
                            writeEnable:NO
                              rasterize:YES
                       compactRegisters:YES
                         attributeFetch:attributes
                               commands:commands
                                  error:&error];
            NV2AMetalWritableEncoding *b =
                [executor encodeProgram:program
                               uniforms:&u
                        attributeBuffer:attributes.attributes
                                  first:0
                                  count:1
                                 access:access
                            writeEnable:NO
                              rasterize:YES
                       compactRegisters:NO
                               commands:commands
                                  error:&error];
            require(a && warm && b, error);
            assert([a canUsePendingReadOnlyResultForCommands:commands] ==
                       valid &&
                   [warm canUsePendingReadOnlyResultForCommands:commands] ==
                       valid &&
                   [program valueForKey:@"fetchProofInputs"] == sourceKey);
            require([commands submitWithError:&error] &&
                        [commands waitUntilIdleWithError:&error],
                    error);
            NV2AMetalWritableResult *compact = [a resolveWithError:NULL];
            NV2AMetalWritableResult *warmResult = [warm resolveWithError:NULL];
            NV2AMetalWritableResult *full = [b resolveWithError:NULL];
            assert(!!compact == valid && !!warmResult == valid &&
                   !!full == valid);
            id<MTLBuffer> coldFault = [a valueForKey:@"raw"],
                          warmFault = [warm valueForKey:@"raw"],
                          fullRaw = [b valueForKey:@"raw"],
                          coldVertices = [a valueForKey:@"vertices"],
                          warmVertices = [warm valueForKey:@"vertices"],
                          fullVertices = [b valueForKey:@"vertices"];
            uint32_t expectedFault =
                ((const NV2AMetalProgramOutput *)fullRaw.contents)[0].fault;
            assert(*(const uint32_t *)coldFault.contents == expectedFault &&
                   *(const uint32_t *)warmFault.contents == expectedFault &&
                   !memcmp(coldVertices.contents, fullVertices.contents,
                           sizeof(NV2AMetalVertex)) &&
                   !memcmp(warmVertices.contents, fullVertices.contents,
                           sizeof(NV2AMetalVertex)));
            if (valid) {
                NSData *image = [NSData dataWithBytes:compact.vertices.contents
                                               length:sizeof(NV2AMetalVertex)];
                assert(
                    !memcmp(image.bytes, full.vertices.contents, image.length));
                assert(!memcmp(warmResult.vertices.contents,
                               full.vertices.contents, image.length) &&
                       [compact.constants isEqual:full.constants] &&
                       [warmResult.constants isEqual:full.constants] &&
                       [compact.written isEqual:full.written] &&
                       [warmResult.written isEqual:full.written]);
                if (mode == 0)
                    first = image;
                if (mode == 1)
                    assert(![image isEqualToData:first]);
            }
            cases++;
        }
    assert(cases == 12);
    puts("Proof lane GPU:12 cold/warm-compact/full triples with an intervening "
         "constants-only scope;exact vertex/fault/context/write flags;changed "
         "color values still "
         "change "
         "GPU output,root values and unused ARL/USER operand faults still "
         "reject "
         "pending publication PASS");
}
#endif
