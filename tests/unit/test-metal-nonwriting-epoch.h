/* Write-enabled captures with proven absent stores versus full serial XF.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_NONWRITING_EPOCH_H
#define TEST_METAL_NONWRITING_EPOCH_H
static unsigned nonwriting_pairs, nonwriting_faults;
static NSMutableData *nonwriting_wire(unsigned raw, unsigned access,
                                      unsigned kind)
{
    NSMutableData *data = metadata_wire(raw ? 6 : 5, 2 | access);
    Token t[4] = { token(1, 0, 96), token(1, 0, 96), token(1, 0, 191),
                   token(1, 0, 96) };
    source(&t[0], 0, 2, 0, 0xe4);
    destination(&t[0], 0x100, 15, 0, 0, 0, 0);
    t[1].word[1] |= 1u << 9;
    source(&t[1], 0, 2, 0, 0xe4);
    destination(&t[1], kind == 0 ? 0x103 : 191, kind == 1 ? 0 : 15, kind == 2,
                0, 0, 0);
    source(&t[2], 0, 3, 0, 0xe4);
    destination(&t[2], 0x109, 15, 0, 0, 0, 0);
    unsigned slots = 3;
    if (kind == 3) {
        t[1] = token(13, 0, 96);
        t[1].word[1] |= 1u << 9;
        source(&t[1], 0, 2, 0, 0xe4);
        destination(&t[1], 0, 0, 0, 0, 0, 0);
        t[2] = token(1, 0, 96);
        source(&t[2], 0, 3, 0, 0xe4);
        destination(&t[2], 0x103, 15, 0, 0, 0, 0);
        t[2].word[3] |= 2;
        source(&t[3], 0, 2, 0, 0xe4);
        destination(&t[3], 0x109, 15, 0, 0, 0, 0);
        metadata_word(data, 8, metadata_read(data, 8) | 2);
        slots = 4;
    }
    t[slots - 1].word[3] |= 1;
    [data setLength:data.length - 48];
    metadata_word(data, 28, slots);
    append(data, t, slots * 16);
    return data;
}
static void nonwriting_epoch_pair(NV2AMetalEpochExecutor *executor,
                                  NV2AMetalCommands *commands,
                                  NV2AMetalPGRAPHVertexState *captured,
                                  id<MTLBuffer> input, unsigned count,
                                  BOOL expectedFault)
{
    assert(captured.writeEnable &&
           !captured.validatedProgram.mayWriteConstants);
    NSData *before = captured.snapshotData;
    NSError *fullError = nil, *error = nil;
    NV2AMetalEpochResult *full = [executor executeState:captured
                                        attributeBuffer:input
                                                  first:3
                                                  count:count
                                                  error:&fullError];
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalEpochEncoding *encoded = [executor encodeRasterState:captured
                                                  attributeBuffer:input
                                                            first:3
                                                            count:count
                                                         commands:commands
                                                            error:&error];
    require(encoded != nil, error);
    id program = [encoded valueForKey:@"program"];
    assert(![program valueForKey:@"context"]);
    id<MTLBuffer> raw = [program valueForKey:@"raw"];
    assert(raw.length == 4);
    finish(commands);
    NV2AMetalEpochResult *compact = [encoded resolveWithError:&error];
    if (expectedFault) {
        assert(!full && !compact && fullError && error &&
               [fullError.domain isEqual:error.domain] &&
               fullError.code == error.code &&
               [fullError.localizedDescription
                   isEqual:error.localizedDescription]);
        nonwriting_faults++;
    } else {
        require(full && compact, error);
        assert(!compact.registers && compact.vertexCount == count &&
               [compact.constants isEqual:full.constants] &&
               [compact.written isEqual:full.written]);
        const uint32_t *dirty = compact.written.bytes;
        for (unsigned i = 0; i < 192; i++)
            assert(!dirty[i]);
        assert([captured stateByApplyingConstants:compact.constants
                                          written:compact.written
                                            error:&error] == captured);
        if (captured.rasterDiscard)
            assert(!compact.vertices);
        else if (count)
            assert(!memcmp(full.vertices.contents, compact.vertices.contents,
                           count * sizeof(NV2AMetalVertex)));
    }
    assert([before isEqual:captured.snapshotData] && captured.writeEnable);
    nonwriting_pairs++;
}
static void nonwriting_epoch_tests(NV2AMetalCommands *commands,
                                   NV2AMetalEpochExecutor *executor)
{
    NSError *error = nil;
    NV2AMetalProgramInput values[264] = { 0 };
    for (unsigned v = 0; v < 264; v++)
        for (unsigned a = 0; a < 16; a++)
            for (unsigned k = 0; k < 4; k++)
                values[v].attributes[a][k] =
                    k == 3 ? 1 : (float)((v + a + k) % 7);
    id<MTLBuffer> staging =
        [commands.device newBufferWithBytes:values
                                     length:sizeof(values)
                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> gpu =
        [commands.device newBufferWithLength:sizeof(values)
                                     options:MTLResourceStorageModePrivate];
    id<MTLBuffer> readback =
        [commands.device newBufferWithLength:sizeof(values)
                                     options:MTLResourceStorageModeShared];
    assert(staging && gpu && readback);
    copyBuffer(commands, staging, gpu);
    const unsigned counts[] = { 0, 1, 3, 17, 257 };
    for (unsigned raw = 0; raw < 2; raw++)
        for (unsigned access = 0; access < 2; access++)
            for (unsigned kind = 0; kind < 3; kind++) {
                NSMutableData *wireData = nonwriting_wire(raw, access, kind);
                const uint32_t edge[] = { 0x7fc00123, 0x80000000, 1,
                                          0x7f800000 };
                for (unsigned k = 0; k < 4; k++)
                    metadata_word(wireData,
                                  32 + sizeof(NV2AMetalProgramInput) +
                                      191 * 16 + k * 4,
                                  edge[k]);
                NV2AMetalPGRAPHVertexState *capture =
                    [[NV2AMetalPGRAPHVertexState alloc]
                        initWithSnapshot:wireData
                                   error:&error];
                require(capture != nil, error);
                assert([wireData isEqual:capture.snapshotData]);
                for (unsigned n = 0; n < 5; n++)
                    nonwriting_epoch_pair(executor, commands, capture, gpu,
                                          counts[n], NO);
                require([commands beginWithError:&error] != nil, error);
                error = nil;
                assert(![executor encodeState:capture
                              attributeBuffer:gpu
                                        first:3
                                        count:1
                                     commands:commands
                                        error:&error] &&
                       error);
                [commands cancel];
                /* Rebuild effect metadata from changed untrusted tokens,even
                 * warm. */
                NSUInteger tokenOffset = wireData.length - 48;
                uint32_t word = metadata_read(wireData, tokenOffset + 16 + 12);
                word &= ~((1u << 11) | (255u << 3) | (15u << 12) | (1u << 2));
                word |= 191u << 3 | 15u << 12;
                metadata_word(wireData, tokenOffset + 16 + 12, word);
                NV2AMetalPGRAPHVertexState *writer =
                    [[NV2AMetalPGRAPHVertexState alloc]
                        initWithSnapshot:wireData
                                   error:&error];
                require(writer != nil, error);
                assert(writer.validatedProgram.mayWriteConstants);
                require([commands beginWithError:&error] != nil, error);
                error = nil;
                assert(![executor encodeRasterState:writer
                                    attributeBuffer:gpu
                                              first:3
                                              count:1
                                           commands:commands
                                              error:&error] &&
                       error);
                [commands cancel];
            }
    copyBuffer(commands, gpu, readback);
    assert(!memcmp(readback.contents, values, sizeof(values)));
    for (unsigned raw = 0; raw < 2; raw++)
        for (unsigned access = 0; access < 2; access++) {
            NV2AMetalPGRAPHVertexState *capture =
                [[NV2AMetalPGRAPHVertexState alloc]
                    initWithSnapshot:nonwriting_wire(raw, access, 3)
                               error:&error];
            require(capture != nil, error);
            for (unsigned kind = 0; kind < 2; kind++)
                for (unsigned bad = 0; bad < 3; bad++) {
                    for (unsigned v = 0; v < 264; v++)
                        values[v].attributes[1][0] = 0;
                    const unsigned offsets[] = { 0, 8, 16 };
                    values[3 + offsets[bad]].attributes[1][0] =
                        kind ? NAN : 1000;
                    memcpy(staging.contents, values, sizeof(values));
                    copyBuffer(commands, staging, gpu);
                    nonwriting_epoch_pair(executor, commands, capture, gpu, 17,
                                          YES);
                    values[3 + offsets[bad]].attributes[1][0] = 0;
                    memcpy(staging.contents, values, sizeof(values));
                    copyBuffer(commands, staging, gpu);
                    nonwriting_epoch_pair(executor, commands, capture, gpu, 17,
                                          NO);
                }
        }
    assert(nonwriting_pairs == 108 && nonwriting_faults == 24);
    printf("Nonwriting enabled XF:%u full-serial/parallel pairs,%u "
           "first/middle/last address faults and24 "
           "retries;USER/FULL/raw/raster/empty/private suffixes,NaN constant "
           "bits,zero dirty/context,immutable capture/WriteEnable/wire and "
           "warm restore-writer rejection PASS\n",
           nonwriting_pairs, nonwriting_faults);
    fflush(stdout);
}
#endif
