/* Compact Raw program output is count/context, not a raster allocation.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DISCARDED_PROGRAM_H
#define TEST_METAL_DISCARDED_PROGRAM_H
static void discarded_program_tests(void)
{
    const unsigned counts[] = { 0, 1, 3, 17, 257, 512 };
    unsigned cases = 0, retries = 0;
    for (unsigned write = 0; write < 2; write++)
        for (unsigned n = 0; n < 6; n++) {
            @autoreleasepool {
                fixture();
                NSError *error = nil;
                PGRAPHState *pg = &state->pgraph;
                unsigned count = counts[n];
                pg->regs_[NV_PGRAPH_CSV0_D] = 2u << 30;
                pg->enable_vertex_program_write = write;
                feedback_program(191, 15);
                float positions[514][4];
                NV2AMetalProgramInput decoded[520] = { 0 };
                for (unsigned v = 0; v < 520; v++) {
                    decoded[v].attributes[0][0] = v % 5;
                    decoded[v].attributes[0][1] = v % 7;
                    decoded[v].attributes[0][2] = 32768;
                    decoded[v].attributes[0][3] = 1;
                    for (unsigned k = 0; k < 4; k++)
                        decoded[v].attributes[4][k] = k + 1;
                    if (v < 514)
                        memcpy(positions[v], decoded[v].attributes[0], 16);
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
                require([draw prepareVertexStateChangeWithError:&error], error);
                if (count)
                    expect_context(191, 15, count, write);
                else
                    for (unsigned row = 0; row < 192; row++)
                        assert(!pg->vsh_constants_dirty[row]);
                NSData *vertexWire = draw.vertexSnapshot;
                NV2AMetalPGRAPHVertexState *captured =
                    [[NV2AMetalPGRAPHVertexState alloc]
                        initWithSnapshot:vertexWire
                                   error:&error];
                require(captured && captured.programmed &&
                            captured.rasterDiscard &&
                            captured.writeEnable == write,
                        error);
                NV2AMetalEpochExecutor *epoch = [draw valueForKey:@"epoch"];
                id<MTLBuffer> input = [surfaces.cache.commands.device
                    newBufferWithBytes:decoded
                                length:sizeof(decoded)
                               options:MTLResourceStorageModeShared];
                assert(input);
                NV2AMetalEpochResult *compact =
                    [epoch executeRasterState:captured
                              attributeBuffer:input
                                        first:3
                                        count:count
                                        error:&error];
                require(compact != nil, error);
                NV2AMetalEpochResult *full = [epoch executeState:captured
                                                 attributeBuffer:input
                                                           first:3
                                                           count:count
                                                           error:&error];
                require(full != nil, error);
                NSData *zero = [NSMutableData
                    dataWithLength:count * sizeof(NV2AMetalVertex)];
                assert(!compact.vertices && !compact.registers &&
                       compact.vertexCount == count &&
                       [compact.constants isEqual:full.constants] &&
                       [compact.written isEqual:full.written]);
                assert(!count || !memcmp(full.vertices.contents, zero.bytes,
                                         zero.length));
                error = nil;
                assert(![epoch executeRasterState:captured
                                  attributeBuffer:input
                                            first:521
                                            count:1
                                            error:&error] &&
                       error);
                error = nil;
                require([draw prepareVertexStateChangeWithError:&error], error);
                if (count)
                    expect_context(191, 15, count, write);
                NSData *pendingWire = [draw pendingSnapshotWithError:&error];
                NSData *beginWire = [draw beginSnapshotWithError:&error];
                require(pendingWire.length > 12 && beginWire, error);
                NV2AMetalPendingArchive *archive = [[NV2AMetalPendingArchive
                    alloc]
                    initWithData:[pendingWire
                                     subdataWithRange:NSMakeRange(
                                                          12,
                                                          pendingWire.length -
                                                              12)]
                           limit:524287
                           error:&error];
                require(archive != nil, error);
                assert(archive.vertices.count == (count ? 1u : 0u));
                if (count)
                    assert([archive.vertices[0] isEqual:zero]);
                NV2AMetalPendingJournal *journal =
                    [draw valueForKey:@"pending"];
                for (NSArray *spans in journal.retainedStreams)
                    for (NV2AMetalPendingSpan *span in spans)
                        assert([span.resource
                            isMemberOfClass:NV2AMetalDiscardedVertices.class]);
                require([draw discardForRestoreWithError:&error], error);
                require([draw restoreVertexSnapshot:vertexWire error:&error],
                        error);
                require([draw restoreBeginSnapshot:beginWire error:&error],
                        error);
                require([draw restorePendingSnapshot:pendingWire error:&error],
                        error);
                require([draw beginWithError:&error], error);
                assert([[draw pendingSnapshotWithError:&error]
                    isEqual:pendingWire]);
                pg->draw_arrays_length = 1;
                pg->draw_arrays_count[0] = count + 1;
                uint32_t originalOpcode = pg->program_data[0][1];
                pg->program_data[0][1] = UINT32_MAX;
                error = nil;
                assert(![draw prepareVertexStateChangeWithError:&error] &&
                       error);
                assert(
                    !memcmp(original, pg->vertex_attributes, sizeof(original)));
                pg->program_data[0][1] = originalOpcode;
                error = nil;
                require([draw prepareVertexStateChangeWithError:&error], error);
                expect_context(191, 15, count + 1, write);
                retries++;
                pg->draw_arrays_count[0] = count + 2;
                dma[2].limit = 15;
                error = nil;
                assert(![draw prepareVertexStateChangeWithError:&error] &&
                       error);
                expect_context(191, 15, count + 1, write);
                dma[2].limit = sizeof(positions) - 1;
                error = nil;
                require([draw prepareVertexStateChangeWithError:&error], error);
                expect_context(191, 15, count + 2, write);
                retries++;
                journal = [draw valueForKey:@"pending"];
                for (NSArray *spans in journal.retainedStreams)
                    for (NV2AMetalPendingSpan *span in spans)
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
                assert([suffix.vertices[0] isEqual:allZero] && !pg->draw_time &&
                       !memcmp(original, pg->vertex_attributes,
                               sizeof(original)) &&
                       !surfaces.color && !surfaces.zeta);
                require([draw discardForRestoreWithError:&error], error);
                qemu_mutex_unlock(&pg->lock);
                color(1, 1, 0xffff0000);
                cases++;
            }
        }
    assert(cases == 12 && retries == 24);
    puts("Discarded programmable XF:12 Readonly/Writable empty/suffix/large "
         "cases;no raster buffer or binding,full diagnostic GPU-zero "
         "oracle,exact constants/dirty/Current/VRAM,canonical "
         "snapshot/count-only restore,invalid range/opcode/DMA rejection and24 "
         "no-replay retries PASS");
    groups++;
}
#endif
