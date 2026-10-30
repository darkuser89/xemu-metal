/* Fixed Raw XF keeps only count/context; snapshots retain exact zero bytes.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DISCARDED_FIXED_H
#define TEST_METAL_DISCARDED_FIXED_H
static void discarded_fixed_tests(void)
{
    const unsigned counts[] = { 0, 1, 3, 17, 257, 512 };
    for (unsigned test = 0; test < 6; test++) {
        fixture();
        NSError *error = nil;
        PGRAPHState *pg = &state->pgraph;
        unsigned count = counts[test];
        float positions[514][4];
        NV2AMetalProgramInput decoded[520] = { 0 };
        for (unsigned v = 0; v < 514; v++) {
            positions[v][0] = v % 5;
            positions[v][1] = v % 7;
            positions[v][2] = 32768;
            positions[v][3] = 1;
            memcpy(decoded[v].attributes[0], positions[v], 16);
        }
        dma[2].limit = sizeof(positions) - 1;
        cpu_write(16384, sizeof(positions));
        memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
        pg->draw_arrays_length = count != 0;
        pg->draw_arrays_count[0] = count;
        pg->regs_[NV_PGRAPH_CONTROL_0] = 0;
        pg->surface_shape = (SurfaceShape){ 0 };
        qemu_mutex_lock(&pg->lock);
        require([draw beginWithError:&error], error);
        VertexAttribute original[16];
        memcpy(original, pg->vertex_attributes, sizeof(original));
        NV2AMetalEpochExecutor *epoch = [draw valueForKey:@"epoch"];
        NV2AMetalVertexFixed *fixed = [epoch valueForKey:@"fixed"];
        uint64_t general =
            [[fixed valueForKey:@"generalDispatches"] unsignedLongLongValue];
        uint64_t specialized = [[fixed valueForKey:@"specializedDispatches"]
            unsignedLongLongValue];
        require([draw prepareVertexStateChangeWithError:&error], error);
        assert([[fixed valueForKey:@"generalDispatches"]
                   unsignedLongLongValue] == general &&
               [[fixed valueForKey:@"specializedDispatches"]
                   unsignedLongLongValue] == specialized);
        NSData *vertices = draw.vertexSnapshot;
        NV2AMetalPGRAPHVertexState *captured =
            [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:vertices
                                                           error:&error];
        require(captured && captured.rasterDiscard && !captured.programmed,
                error);
        id<MTLBuffer> input = [surfaces.cache.commands.device
            newBufferWithBytes:decoded
                        length:sizeof(decoded)
                       options:MTLResourceStorageModeShared];
        NV2AMetalCommands *epochCommands = [epoch valueForKey:@"commands"];
        NV2AMetalSubmission *receipt = epochCommands.lastSubmitted;
        NV2AMetalEpochResult *compact = [epoch executeRasterState:captured
                                                  attributeBuffer:input
                                                            first:3
                                                            count:count
                                                            error:&error];
        require(compact != nil, error);
        assert(!compact.vertices && !compact.registers &&
               compact.vertexCount == count &&
               epochCommands.lastSubmitted == receipt);
        NV2AMetalEpochResult *full = [epoch executeState:captured
                                         attributeBuffer:input
                                                   first:3
                                                   count:count
                                                   error:&error];
        require(full != nil, error);
        NSData *zero =
            [NSMutableData dataWithLength:count * sizeof(NV2AMetalVertex)];
        assert([compact.constants isEqualToData:full.constants] &&
               [compact.written isEqualToData:full.written] &&
               (!count ||
                !memcmp(full.vertices.contents, zero.bytes, zero.length)));
        receipt = epochCommands.lastSubmitted;
        assert(![epoch executeRasterState:captured
                          attributeBuffer:input
                                    first:521
                                    count:1
                                    error:&error] &&
               error && epochCommands.lastSubmitted == receipt);
        NSData *pendingWire = [draw pendingSnapshotWithError:&error];
        NSData *bound = [draw beginSnapshotWithError:&error];
        require(pendingWire && bound, error);
        NV2AMetalPendingArchive *archive = [[NV2AMetalPendingArchive alloc]
            initWithData:[pendingWire
                             subdataWithRange:NSMakeRange(
                                                  12, pendingWire.length - 12)]
                   limit:524287
                   error:&error];
        require(archive != nil, error);
        assert(archive.vertices.count == (count ? 1u : 0u));
        if (count)
            assert([archive.vertices[0] isEqualToData:zero]);
        require([draw discardForRestoreWithError:&error], error);
        require([draw restoreVertexSnapshot:vertices error:&error], error);
        require([draw restoreBeginSnapshot:bound error:&error], error);
        require([draw restorePendingSnapshot:pendingWire error:&error], error);
        require([draw beginWithError:&error], error);
        assert(
            [[draw pendingSnapshotWithError:&error] isEqualToData:pendingWire]);
        pg->draw_arrays_length = 1;
        pg->draw_arrays_count[0] = count + 1;
        pg->surface_scale_factor = 0;
        assert(![draw prepareVertexStateChangeWithError:&error] && error);
        assert(!memcmp(original, pg->vertex_attributes, sizeof(original)));
        pg->surface_scale_factor = 1;
        require([draw prepareVertexStateChangeWithError:&error], error);
        pg->draw_arrays_count[0] = count + 2;
        dma[2].limit = 15;
        error = nil;
        BOOL failed = ![draw prepareVertexStateChangeWithError:&error];
        assert(failed && error &&
               [error.localizedDescription
                   isEqualToString:@"NV2A vertex stream exceeds DMA span"]);
        assert(!memcmp(original, pg->vertex_attributes, sizeof(original)));
        dma[2].limit = sizeof(positions) - 1;
        require([draw prepareVertexStateChangeWithError:&error], error);
        NV2AMetalPendingJournal *journal = [draw valueForKey:@"pending"];
        assert(journal.retainedStreams.count == 1 &&
               journal.retainedStreams[0].count == (count ? 3u : 2u));
        for (NV2AMetalPendingSpan *span in journal.retainedStreams[0])
            assert([span.resource
                isMemberOfClass:NV2AMetalDiscardedVertices.class]);
        require([surfaces.cache submitWithError:&error] &&
                    [surfaces.cache waitUntilIdleWithError:&error],
                error);
        NV2AMetalPendingArchive *suffix = nv2a_metal_pending_capture(
            journal, surfaces.cache.commands, &error);
        require(suffix != nil, error);
        NSData *allZero = [NSMutableData
            dataWithLength:(count + 2) * sizeof(NV2AMetalVertex)];
        assert([suffix.vertices[0] isEqualToData:allZero] && !pg->draw_time &&
               !memcmp(original, pg->vertex_attributes, sizeof(original)));
        require([draw discardForRestoreWithError:&error], error);
        qemu_mutex_unlock(&pg->lock);
        color(1, 1, 0xffff0000);
    }
    groups++;
    puts("Discarded Fixed XF:6 empty/suffix/large NOP cases;zero transform "
         "dispatch/output buffer,"
         "full-GPU zero-byte oracle,unchanged "
         "constants/dirty/Current/VRAM,canonical snapshot/"
         "buffer-free raw restore,invalid range/state/fetch rejection and12 "
         "retries PASS");
}
#endif
