/* Compact XF fault reduction against complete native diagnostic outputs.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_READONLY_FAULT_SUMMARY_H
#define TEST_METAL_READONLY_FAULT_SUMMARY_H

static BOOL readonly_summary_bad(NSUInteger vertex, NSUInteger count,
                                 unsigned pattern)
{
    return pattern == 1 ? vertex == 0 :
           pattern == 2 ? vertex == count / 2 :
           pattern == 3 ? vertex == count - 1 :
           pattern == 4 ? YES :
                          pattern == 5 && (vertex & 1);
}

static void readonly_summary_pair(NV2AMetalWritableProgram *program,
                                  NV2AMetalCommands *commands,
                                  NV2AMetalPGRAPHVertexState *state,
                                  NSUInteger count, unsigned pattern,
                                  unsigned access, BOOL rasterize,
                                  unsigned *cases, uint64_t *words)
{
    NSError *error = nil;
    NSMutableData *data = [NSMutableData
        dataWithLength:(count + 3) * sizeof(NV2AMetalProgramInput)];
    NV2AMetalProgramInput *inputs = data.mutableBytes;
    for (NSUInteger v = 0; v < count + 3; v++) {
        inputs[v].attributes[0][0] = (v % 8) * .125f;
        inputs[v].attributes[0][1] = .5f;
        inputs[v].attributes[0][2] = 32768;
        inputs[v].attributes[0][3] = 1;
        BOOL bad = v < 2 || v == count + 2 ||
                   readonly_summary_bad(v - 2, count, pattern);
        inputs[v].attributes[1][0] = bad ? (v & 1 ? -1000 : 1000) : 0;
    }
    id<MTLBuffer> source =
        [commands.device newBufferWithBytes:inputs
                                     length:data.length
                                    options:MTLResourceStorageModeShared];
    assert(source);
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalProgramUniforms u = state.programUniforms;
    NV2AMetalWritableEncoding *encoded[2];
    for (unsigned compact = 0; compact < 2; compact++) {
        encoded[compact] = [program encodeProgram:state.validatedProgram
                                         uniforms:&u
                                  attributeBuffer:source
                                            first:2
                                            count:count
                                           access:access
                                      writeEnable:NO
                                        rasterize:rasterize
                                 compactRegisters:compact
                                         commands:commands
                                            error:&error];
        require(encoded[compact] != nil, error);
    }
    id<MTLBuffer> full = [encoded[0] valueForKey:@"raw"];
    id<MTLBuffer> mask = [encoded[1] valueForKey:@"raw"];
    assert(full.length == MAX(count, 1u) * sizeof(NV2AMetalProgramOutput));
    assert(mask.length == sizeof(uint32_t) && !*(uint32_t *)mask.contents);
    finish(commands);
    assert(!memcmp(data.bytes, source.contents, data.length));
    const NV2AMetalProgramOutput *raw = full.contents;
    uint32_t expected = 0;
    for (NSUInteger v = 0; v < count; v++) {
        assert(!!raw[v].fault == readonly_summary_bad(v, count, pattern));
        expected |= raw[v].fault;
    }
    assert(*(uint32_t *)mask.contents == expected);
    id<MTLBuffer> a = [encoded[0] valueForKey:@"vertices"];
    id<MTLBuffer> b = [encoded[1] valueForKey:@"vertices"];
    if (rasterize)
        assert(
            a.length == b.length &&
            !memcmp(a.contents, b.contents, count * sizeof(NV2AMetalVertex)));
    else {
        assert(!b);
        const uint8_t *bytes = a.contents;
        for (NSUInteger i = 0; i < count * sizeof(NV2AMetalVertex); i++)
            assert(!bytes[i]);
    }
    NSError *fullError = nil, *maskError = nil;
    NV2AMetalWritableResult *f = [encoded[0] resolveWithError:&fullError];
    NV2AMetalWritableResult *c = [encoded[1] resolveWithError:&maskError];
    if (expected) {
        assert(!f && !c && fullError && maskError &&
               [fullError.domain isEqual:maskError.domain] &&
               fullError.code == maskError.code &&
               [fullError.localizedDescription
                   isEqual:maskError.localizedDescription]);
    } else {
        require(f && c, maskError);
        assert(f.registers && !c.registers && f.vertexCount == count &&
               c.vertexCount == count && [f.constants isEqual:c.constants] &&
               [f.written isEqual:c.written]);
    }
    (*cases)++;
    *words += count;
}

static void readonly_fault_summary_tests(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NSMutableData *capture = [wire(5, 1, 0) mutableCopy];
    Token tokens[3] = { token(1, 0, 0), token(13, 0, 0), token(1, 0, 96) };
    source(&tokens[0], 0, 2, 0, 0xe4);
    destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
    tokens[1].word[1] |= 1u << 9;
    source(&tokens[1], 0, 2, 0, 0xe4);
    destination(&tokens[1], 0, 0, 0, 0, 8, 0);
    source(&tokens[2], 0, 3, 0, 0xe4);
    destination(&tokens[2], 0x109, 15, 0, 0, 0, 0);
    tokens[2].word[3] |= 3;
    NSMutableData *bytes = [NSMutableData new];
    append(bytes, tokens, sizeof(tokens));
    [capture replaceBytesInRange:NSMakeRange(capture.length - bytes.length,
                                             bytes.length)
                       withBytes:bytes.bytes];
    metadata_word(capture, 8, 3);
    NV2AMetalPGRAPHVertexState *state =
        [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:capture
                                                       error:&error];
    NV2AMetalWritableProgram *program =
        [[NV2AMetalWritableProgram alloc] initWithDevice:commands.device
                                                   error:&error];
    require(state && program, error);
    unsigned cases = 0;
    uint64_t words = 0;
    readonly_summary_pair(program, commands, state, 1, 1, 0, YES, &cases,
                          &words);
    assert(metadata_counter(program, @"interpreterDispatches") == 2 &&
           !metadata_counter(program, @"specializedDispatches"));
    const NSUInteger counts[] = { 0, 1, 2, 31, 32, 33, 257, 4097 };
    for (unsigned n = 0; n < sizeof(counts) / sizeof(*counts); n++)
        for (unsigned pattern = 0; pattern < (counts[n] ? 6u : 1u); pattern++)
            for (unsigned access = 0; access < 2; access++)
                for (unsigned rasterize = 0; rasterize < 2; rasterize++)
                    @autoreleasepool {
                        readonly_summary_pair(program, commands, state,
                                              counts[n], pattern, access,
                                              rasterize, &cases, &words);
                    }
    dispatch_queue_t queue = [program valueForKey:@"specializationQueue"];
    dispatch_sync(queue, ^{
                  });
    assert(metadata_counter(program, @"specializationSuccesses") == 1);
    NSUInteger before = metadata_counter(program, @"specializedDispatches");
    readonly_summary_pair(program, commands, state, 33, 4, 1, YES, &cases,
                          &words);
    assert(metadata_counter(program, @"specializedDispatches") == before + 2);
    before = metadata_counter(program, @"specializedDispatches");
    readonly_summary_pair(program, commands, state, 33, 0, 1, NO, &cases,
                          &words);
    readonly_summary_pair(program, commands, state, 33, 4, 1, NO, &cases,
                          &words);
    assert(metadata_counter(program, @"specializedDispatches") == before + 4);
    printf("Readonly XF fault summary:%u exact pairs/%llu vertex words;"
           "4-byte mask,empty/sparse/dense faults,USER/FULL,raster on/off,"
           "suffix guards,cold/specialized parity,constants and error "
           "contracts PASS\n",
           cases, (unsigned long long)words);
}
#endif
