/* Non-TCG dirty fallback through real PGRAPH DMA fetch capture.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_FETCH_DIRTY_SOURCE_H
#define TEST_METAL_FETCH_DIRTY_SOURCE_H
static void fetch_dirty_source_tests(void)
{
    unsigned cases = 0;
    for (unsigned submitted = 0; submitted < 2; submitted++)
        for (unsigned indexed = 0; indexed < 2; indexed++) {
            reset();
            NSError *error = nil;
            require([surfaces discardForRestoreWithError:&error], error);
            PGRAPHState *pg = &state->pgraph;
            dma_a.address = 0;
            dma_a.limit = 65535;
            pg->vertex_attributes[0] = (VertexAttribute){
                .offset = 65520,
                .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                .size = 4,
                .count = 4,
                .stride = 16
            };
            pg->vertex_attributes[0].inline_value[0] = -1;
            pg->vertex_attributes[0].inline_value[3] = 1;
            if (indexed) {
                pg->inline_elements_length = 1;
                pg->inline_elements[0] = 0;
            } else {
                pg->draw_arrays_length = 1;
                pg->draw_arrays_count[0] = 1;
            }
            uint32_t marker = 0x12345678;
            memcpy(state->vram_ptr + 60000, &marker, sizeof(marker));
            require([surfaces prepareGPUReadAtAddress:60000
                                               length:4
                                                error:&error],
                    error);
            NV2AMetalCommands *commands = surfaces.commands;
            id<MTLBuffer> output = [commands.device
                newBufferWithLength:4
                            options:MTLResourceStorageModeShared];
            assert(output);
            require([commands addResource:output error:&error], error);
            id<MTL4ComputeCommandEncoder> e =
                [commands.commandBuffer computeCommandEncoder];
            assert(e);
            [e barrierAfterQueueStages:MTLStageAll
                          beforeStages:MTLStageBlit
                     visibilityOptions:MTL4VisibilityOptionDevice];
            [e copyFromBuffer:surfaces.vram
                     sourceOffset:60000
                         toBuffer:output
                destinationOffset:0
                             size:4];
            [e barrierAfterStages:MTLStageBlit
                beforeQueueStages:MTLStageAll
                visibilityOptions:MTL4VisibilityOptionDevice];
            [e endEncoding];
            id<MTLSharedEvent> gate = [commands.device newSharedEvent];
            assert(gate);
            Ivar ivar =
                class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
            id<MTL4CommandQueue> queue = object_getIvar(commands, ivar);
            [queue waitForEvent:gate value:1];
            NV2AMetalSurfaceRecording *token = surfaces.recording;
            id recording = commands.commandBuffer;
            if (submitted)
                require([surfaces submitWithError:&error], error);
            id receipt = commands.lastSubmitted;
            uint64_t serial = commands.recordingSerial;
            float p[4] = { 3.25f, 4.5f, 5.75f, 1 };
            memcpy(state->vram_ptr + 65520, p, sizeof(p));
            dirty_last = true;
            tcg_allowed = false;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                           dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                             if (!gate.signaledValue)
                                 gate.signaledValue = 2;
                           });
            NSArray<NV2AMetalPGRAPHFetchBatch *> *b =
                [adapter encodeIndependentSnapshotsWithError:&error];
            require(b != nil, error);
            assert(b.count == 1 && !dirty_last && !gate.signaledValue &&
                   commands.lastSubmitted == receipt &&
                   commands.recordingSerial == serial);
            assert(adapter.encodingCommands != commands);
            assert(token.submitted == !!submitted && !token.completed &&
                   !token.cancelled);
            if (!submitted)
                assert(commands.commandBuffer == recording &&
                       surfaces.recording == token);
            scalar(pg->vertex_attributes[0].inline_value[0], -1);
            assert(!nv2a_metal_try_cpu_access(surfaces.cpuAccessGuard, 65520,
                                              16, YES));
            require([adapter completeWithError:&error], error);
            assert(!gate.signaledValue && !token.completed);
            gate.signaledValue = 1;
            if (!submitted)
                require([surfaces submitWithError:&error], error);
            require([surfaces waitUntilIdleWithError:&error], error);
            assert(*(uint32_t *)output.contents == marker);
            for (unsigned i = 0; i < 4; i++) {
                scalar(values(b[0])[0].attributes[0][i], p[i]);
                scalar(pg->vertex_attributes[0].inline_value[i], p[i]);
            }
            tcg_allowed = true;
            groups++;
            cases++;
        }
    printf("PGRAPH dirty DMA capture: %u array/index/pending/submitted cases "
           "PASS\n",
           cases);
}
#endif
