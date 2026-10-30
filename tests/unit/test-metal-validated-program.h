/* Capture-owned decoder data, raw-token parity and untrusted wire validation.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_VALIDATED_PROGRAM_H
#define TEST_METAL_VALIDATED_PROGRAM_H
static void metadata_word(NSMutableData *data, NSUInteger offset, uint32_t word)
{
    uint8_t bytes[] = { word >> 24, word >> 16, word >> 8, word };
    assert(offset + 4 <= data.length);
    [data replaceBytesInRange:NSMakeRange(offset, 4) withBytes:bytes];
}
static uint32_t metadata_read(NSData *data, NSUInteger offset)
{
    assert(offset + 4 <= data.length);
    const uint8_t *p = (const uint8_t *)data.bytes + offset;
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 |
           p[3];
}
static NSMutableData *metadata_wire(unsigned version, unsigned policy)
{
    NSMutableData *data =
        [wire(version == 6 ? 5 : version, 1, policy) mutableCopy];
    if (version == 6) {
        metadata_word(data, 4, 6);
        metadata_word(data, 8, metadata_read(data, 8) | 64);
        memset((uint8_t *)data.mutableBytes + 32 +
                   sizeof(NV2AMetalProgramInput) +
                   sizeof(((NV2AMetalProgramUniforms *)0)->constants),
               0,
               sizeof(NV2AMetalProgramUniforms) -
                   sizeof(((NV2AMetalProgramUniforms *)0)->constants));
    }
    return data;
}
static NSUInteger metadata_counter(id program, NSString *key)
{
    return [[program valueForKey:key] unsignedIntegerValue];
}
static void metadata_buffer(id<MTLBuffer> a, id<MTLBuffer> b)
{
    assert(a && b && a.length == b.length);
    assert(!memcmp(a.contents, b.contents, a.length));
}
static void metadata_result(NV2AMetalEpochResult *a, NV2AMetalWritableResult *b,
                            BOOL compact, BOOL discard)
{
    assert(a.vertexCount == b.vertexCount);
    if (compact)
        assert(!a.registers);
    else
        metadata_buffer(a.registers, b.registers);
    if (compact && discard) {
        assert(!a.vertices);
        const uint8_t *bytes = b.vertices.contents;
        for (NSUInteger i = 0; i < b.vertexCount * sizeof(NV2AMetalVertex); i++)
            assert(!bytes[i]);
    } else {
        metadata_buffer(a.vertices, b.vertices);
    }
    assert([a.constants isEqual:b.constants] && [a.written isEqual:b.written]);
}
static void validated_program_tests(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalEpochExecutor *executor =
        [[NV2AMetalEpochExecutor alloc] initWithDevice:commands.device
                                                 error:&error];
    NV2AMetalWritableProgram *raw =
        [[NV2AMetalWritableProgram alloc] initWithDevice:commands.device
                                                   error:&error];
    require(executor && raw, error);
    id cached = [executor valueForKey:@"program"];
    NV2AMetalProgramInput inputs[3] = { 0 };
    for (unsigned v = 0; v < 3; v++)
        for (unsigned a = 0; a < 16; a++)
            for (unsigned k = 0; k < 4; k++)
                inputs[v].attributes[a][k] = (v + a + k + 1) * .125f;
    for (unsigned v = 0; v < 3; v++)
        inputs[v].attributes[0][3] = 1;
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:inputs
                                     length:sizeof(inputs)
                                    options:MTLResourceStorageModeShared];
    assert(attributes);
    unsigned comparisons = 0, rejects = 0;
    for (unsigned version = 1; version <= 6; version++) {
        for (unsigned policy = 0; policy < 4; policy++) {
            NSMutableData *bytes = metadata_wire(version, policy);
            NSData *original = [bytes copy];
            NV2AMetalPGRAPHVertexState *state =
                [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:bytes
                                                               error:&error];
            require(state != nil, error);
            NV2AMetalValidatedProgram *program = state.validatedProgram;
            assert(program && program.tokens == state.programBytes &&
                   program.slots == 3);
            assert(program.instructions.length ==
                   3 * sizeof(NV2AMetalProgramInstruction));
            assert(![program.tokens isKindOfClass:NSMutableData.class] &&
                   ![program.instructions isKindOfClass:NSMutableData.class]);
            assert([state.snapshotData isEqual:original]);
            /* The caller can overwrite its original wire after construction. */
            metadata_word(bytes, bytes.length - 12, UINT32_MAX);
            assert([state.snapshotData isEqual:original]);
            NV2AMetalProgramUniforms u = state.programUniforms;
            NV2AMetalWritableResult *reference =
                [raw executeTokens:state.programBytes.bytes
                             length:state.programBytes.length / 16
                           uniforms:&u
                    attributeBuffer:attributes
                              first:0
                              count:3
                             access:state.fullAccess
                        writeEnable:state.writeEnable
                          rasterize:!state.rasterDiscard
                              error:&error];
            require(reference != nil, error);
            id decoded = [raw valueForKey:@"decodedProgram"];
            id<MTLBuffer> instructions = [decoded valueForKey:@"buffer"];
            assert(instructions.length == program.instructions.length &&
                   !memcmp(instructions.contents, program.instructions.bytes,
                           instructions.length));
            NV2AMetalEpochResult *actual = [executor executeState:state
                                                  attributeBuffer:attributes
                                                            first:0
                                                            count:3
                                                            error:&error];
            require(actual != nil, error);
            metadata_result(actual, reference, NO, state.rasterDiscard);
            comparisons++;
            if (!state.writeEnable) {
                for (unsigned compact = 0; compact < 2; compact++) {
                    require([commands beginWithError:&error] != nil, error);
                    NV2AMetalEpochEncoding *encoded =
                        compact ? [executor encodeRasterState:state
                                              attributeBuffer:attributes
                                                        first:0
                                                        count:3
                                                     commands:commands
                                                        error:&error] :
                                  [executor encodeState:state
                                        attributeBuffer:attributes
                                                  first:0
                                                  count:3
                                               commands:commands
                                                  error:&error];
                    require(encoded != nil, error);
                    finish(commands);
                    actual = [encoded resolveWithError:&error];
                    require(actual != nil, error);
                    metadata_result(actual, reference, compact,
                                    state.rasterDiscard);
                    comparisons++;
                }
            }
        }
        /* Warm GPU entries must not allow corrupted raw wire data to pass. */
        for (unsigned kind = 0; kind < 7; kind++) {
            NSMutableData *bad = metadata_wire(version, 0);
            NSUInteger tokens = bad.length - 48;
            if (kind == 0)
                metadata_word(bad, tokens + 4, UINT32_MAX); /* Opcode. */
            if (kind == 1)
                metadata_word(bad, bad.length - 4,
                              metadata_read(bad, bad.length - 4) &
                                  ~1u); /* Missing END. */
            if (kind == 2)
                metadata_word(bad, tokens + 12,
                              metadata_read(bad, tokens + 12) |
                                  1u); /* Surplus after END. */
            if (kind == 3)
                [bad
                    appendData:[NSMutableData dataWithLength:16]]; /* Length. */
            if (kind == 4)
                metadata_word(bad, 8,
                              metadata_read(bad, 8) ^ 2u); /* ARL flag. */
            if (kind == 5)
                metadata_word(bad,
                              32 + sizeof(NV2AMetalProgramInput) +
                                  offsetof(NV2AMetalProgramUniforms, reserved),
                              1);
            if (kind == 6)
                metadata_word(bad, 24, 0); /* Uniform size. */
            error = nil;
            assert(![[NV2AMetalPGRAPHVertexState alloc]
                initWithSnapshot:bad
                           error:&error]);
            assert(error);
            rejects++;
        }
    }
    assert(comparisons == 64 && rejects == 42);
    assert(!metadata_counter(cached, @"programDecodeCount"));
    assert(metadata_counter(cached, @"programMetadataUploads") == 2);
    assert(metadata_counter(raw, @"programDecodeCount") == 2);

    /* Live raw captures use the same constructor, with a nonzero start slot. */
    PGRAPHState *pg = calloc(1, sizeof(*pg));
    assert(pg);
    SET_MASK(pg->regs_[NV_PGRAPH_CSV0_D], NV_PGRAPH_CSV0_D_MODE, 2);
    pg->regs_[NV_PGRAPH_CSV0_D] |= NV_PGRAPH_CSV0_D_RANGE_MODE;
    SET_MASK(pg->regs_[NV_PGRAPH_CSV0_C], NV_PGRAPH_CSV0_C_CHEOPS_PROGRAM_START,
             17);
    NV2AMetalPGRAPHVertexState *template =
        [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:metadata_wire(5, 1)
                                                       error:&error];
    require(template != nil, error);
    memcpy(pg->program_data[17], template.programBytes.bytes,
           template.programBytes.length);
    NV2AMetalPGRAPHVertexState *live =
        [[NV2AMetalPGRAPHVertexState alloc] initRawProgramWithState:pg
                                                              error:&error];
    require(live != nil, error);
    assert([live.programBytes isEqual:template.programBytes] &&
           live.validatedProgram.slots == 3);
    memset(pg->program_data[17], 0xff, template.programBytes.length);
    assert([live.programBytes isEqual:template.programBytes]);
    assert(![[NV2AMetalPGRAPHVertexState alloc]
        initRawProgramWithState:pg
                          error:&error]);
    NV2AMetalEpochResult *liveResult = [executor executeState:live
                                              attributeBuffer:attributes
                                                        first:0
                                                        count:3
                                                        error:&error];
    require(liveResult != nil, error);
    assert(!metadata_counter(cached, @"programDecodeCount"));
    free(pg);

    Token tokens[3];
    memcpy(tokens, template.programBytes.bytes, sizeof(tokens));
    NV2AMetalValidatedProgram *immutable =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                   length:3
                                                    error:&error];
    require(immutable != nil, error);
    tokens[0].word[1] = UINT32_MAX;
    assert([immutable.tokens isEqual:template.programBytes]);
    assert(![[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                       length:3
                                                        error:&error]);
    const uint32_t *missing = NULL;
    assert(![[NV2AMetalValidatedProgram alloc] initWithTokens:missing
                                                       length:3
                                                        error:&error]);
    assert(![[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                       length:0
                                                        error:&error]);
    assert(![[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                       length:NSUIntegerMax
                                                        error:&error]);
    NV2AMetalProgramUniforms u = template.programUniforms;
    /* Metadata entry points keep per-call validation, including warm hits. */
    for (unsigned kind = 0; kind < 3; kind++) {
        NV2AMetalProgramUniforms bad = u;
        if (kind == 0)
            bad.surface_size[0] = 0;
        error = nil;
        assert(![(NV2AMetalWritableProgram *)cached
             executeProgram:immutable
                   uniforms:&bad
            attributeBuffer:attributes
                      first:kind == 1 ? 4 : 0
                      count:1
                     access:kind == 2 ? 2 : 1
                writeEnable:NO
                  rasterize:YES
                      error:&error]);
        assert(error);
    }
    NV2AMetalValidatedProgram *none = nil;
    assert(![(NV2AMetalWritableProgram *)cached executeProgram:none
                                                      uniforms:&u
                                               attributeBuffer:attributes
                                                         first:0
                                                         count:1
                                                        access:1
                                                   writeEnable:NO
                                                     rasterize:YES
                                                         error:&error]);
    /* A cold metadata owner may disappear after encoding and before submit.
     * The instruction upload must be owned by the command, not its capture. */
    __weak NV2AMetalValidatedProgram *releasedMetadata;
    NV2AMetalEpochEncoding *retainedEncoding;
    NSData *retainedTokens;
    NV2AMetalProgramUniforms retainedUniforms;
    require([commands beginWithError:&error] != nil, error);
    @autoreleasepool {
        NSMutableData *bytes = metadata_wire(5, 0);
        NSUInteger at = bytes.length - 48 + 16 + 4;
        metadata_word(bytes, at,
                      (metadata_read(bytes, at) & ~(255u << 13)) | (97u << 13));
        NV2AMetalPGRAPHVertexState *temporary =
            [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:bytes
                                                           error:&error];
        require(temporary != nil, error);
        releasedMetadata = temporary.validatedProgram;
        retainedTokens = temporary.programBytes;
        retainedUniforms = temporary.programUniforms;
        retainedEncoding = [executor encodeState:temporary
                                 attributeBuffer:attributes
                                           first:0
                                           count:3
                                        commands:commands
                                           error:&error];
        require(retainedEncoding != nil, error);
    }
    assert(!releasedMetadata);
    finish(commands);
    NV2AMetalEpochResult *retainedResult =
        [retainedEncoding resolveWithError:&error];
    NV2AMetalWritableResult *retainedReference =
        [raw executeTokens:retainedTokens.bytes
                     length:retainedTokens.length / 16
                   uniforms:&retainedUniforms
            attributeBuffer:attributes
                      first:0
                      count:3
                     access:0
                writeEnable:NO
                  rasterize:YES
                      error:&error];
    require(retainedResult && retainedReference, error);
    metadata_result(retainedResult, retainedReference, NO, NO);
    comparisons++;
    assert(!metadata_counter(cached, @"programDecodeCount") &&
           metadata_counter(cached, @"programMetadataUploads") == 3);
    NV2AMetalPGRAPHVertexState *fixed =
        [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:wire(4, 0, 0)
                                                       error:&error];
    require(fixed != nil, error);
    assert(!fixed.validatedProgram && !fixed.programBytes.length);
    printf(
        "Validated capture programs: %u exact raw-token/metadata GPU "
        "comparisons, "
        "v1-v6/all policies/full+compact;three metadata uploads,zero encoder "
        "decodes; "
        "%u corrupt warm-cache restores rejected;live start17 "
        "ownership,immutable "
        "tokens/instructions,cold capture release before "
        "submit,span/uniform/access/range "
        "errors PASS;no app\n",
        comparisons, rejects);
}
#endif
