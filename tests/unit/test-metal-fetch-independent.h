/* Independent producer lifetime, publication and surface-record isolation.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_FETCH_INDEPENDENT_H
#define TEST_METAL_FETCH_INDEPENDENT_H
#import <objc/runtime.h>
static BOOL fi_collect_failure;
static BOOL (*fi_original_collect)(id, SEL, NSError **);
static NV2AMetalCommands *fi_observed_commands;
static unsigned fi_idle_waits;
static BOOL (*fi_original_idle)(id, SEL, NSError **);
static BOOL fi_idle(id object, SEL selector, NSError **error)
{
    if (object == fi_observed_commands)
        fi_idle_waits++;
    return fi_original_idle(object, selector, error);
}
static BOOL fi_collect(id object, SEL selector, NSError **error)
{
    if (fi_collect_failure) {
        fi_collect_failure = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.independent.completed"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return fi_original_collect(object, selector, error);
}
static void independent_snapshot_tests(void)
{
    NSError *error = nil;
    Method collect = class_getInstanceMethod(
        NV2AMetalSurfaceCache.class, @selector(collectCompletedWithError:));
    assert(collect);
    Method idle = class_getInstanceMethod(NV2AMetalCommands.class,
                                          @selector(waitUntilIdleWithError:));
    assert(idle);
    fi_idle_waits = 0;
    fi_original_idle = (void *)method_setImplementation(idle, (IMP)fi_idle);
    fi_original_collect =
        (void *)method_setImplementation(collect, (IMP)fi_collect);
    unsigned cases = 0, retries = 0;
    for (unsigned kind = 0; kind < 2; kind++)
        for (unsigned compact = 0; compact < 2; compact++)
            for (unsigned action = 0; action < 6; action++) {
                reset();
                PGRAPHState *pg = &state->pgraph;
                float positions[2][4] = { { 1, 2, 3, 1 }, { 4, 5, 6, 1 } };
                pg->compressed_attrs = 0x1234;
                pg->vertex_attributes[0] = (VertexAttribute){
                    .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                    .size = 4,
                    .count = 4,
                    .stride = 16
                };
                pg->vertex_attributes[0].inline_value[3] = 1;
                if (kind) {
                    pg->inline_array_length = 8;
                    memcpy(pg->inline_array, positions, sizeof(positions));
                } else {
                    pg->inline_buffer_length = 2;
                    pg->vertex_attributes[0].inline_buffer_populated = true;
                    pg->vertex_attributes[0].inline_buffer = &positions[0][0];
                }
                float before[16][4];
                for (unsigned i = 0; i < 16; i++)
                    memcpy(before[i], pg->vertex_attributes[i].inline_value,
                           16);
                require([surfaces prepareGPUReadAtAddress:60000
                                                   length:4
                                                    error:&error],
                        error);
                id recording = surfaces.commands.commandBuffer;
                NV2AMetalSurfaceRecording *token = surfaces.recording;
                uint32_t value = 0x12345678, zero = 0;
                id<MTLBuffer> source = [surfaces.commands.device
                    newBufferWithBytes:&value
                                length:4
                               options:MTLResourceStorageModeShared];
                id<MTLBuffer> result = [surfaces.commands.device
                    newBufferWithBytes:&zero
                                length:4
                               options:MTLResourceStorageModeShared];
                assert(source && result);
                require([surfaces.commands addResource:source error:&error],
                        error);
                require([surfaces.commands addResource:result error:&error],
                        error);
                id<MTL4ComputeCommandEncoder> e =
                    [surfaces.commands.commandBuffer computeCommandEncoder];
                assert(e);
                [e copyFromBuffer:source
                         sourceOffset:0
                             toBuffer:result
                    destinationOffset:0
                                 size:4];
                [e endEncoding];
                NSArray<NV2AMetalPGRAPHFetchBatch *> *b =
                    compact ?
                        [adapter
                            encodeIndependentSnapshotsWithPrefixes:@[ @1 ]
                                                             error:&error] :
                        [adapter encodeIndependentSnapshotsWithError:&error];
                require(b != nil, error);
                NV2AMetalCommands *producer = adapter.encodingCommands;
                fi_observed_commands = producer;
                assert(b.count == 1 && producer &&
                       producer != surfaces.commands && producer.commandBuffer);
                if (kind)
                    pg->inline_array[4] = 0;
                else
                    positions[1][0] = 999;
                if (action) {
                    id<MTLSharedEvent> cancelGate = nil;
                    if (action == 2) {
                        cancelGate = [producer.device newSharedEvent];
                        assert(cancelGate);
                        Ivar ivar = class_getInstanceVariable(
                            NV2AMetalCommands.class, "_queue");
                        assert(ivar);
                        id<MTL4CommandQueue> queue =
                            object_getIvar(producer, ivar);
                        [queue waitForEvent:cancelGate value:1];
                        id<MTLSharedEvent> gate = cancelGate;
                        dispatch_after(
                            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                            dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                              if (!gate.signaledValue)
                                  gate.signaledValue = 2;
                            });
                    }
                    if (action != 1) {
                        require([adapter submitWithError:&error], error);
                        if (action != 2)
                            require([producer
                                        waitForSubmission:producer.lastSubmitted
                                                    error:&error],
                                    error);
                    }
                    if (action >= 3) {
                        uint32_t *faults = b[0].fetch.faults.contents;
                        if (action == 5)
                            fi_collect_failure = YES;
                        else if (action == 3) {
                            faults[0] = 1;
                            *(uint32_t *)((uint8_t *)faults +
                                          b[0].fetch.faultSummaryOffset) = 1;
                        } else
                            faults[b[0].fetch.vertexCount] = 1;
                        assert(![adapter completeWithError:&error] && error);
                        assert(!fi_collect_failure);
                    } else
                        [adapter cancel];
                    if (action == 2) {
                        assert(!cancelGate.signaledValue);
                        cancelGate.signaledValue = 1;
                        require([producer
                                    waitForSubmission:producer.lastSubmitted
                                                error:&error],
                                error);
                        assert(values(b[0])[compact ? 0 : 1].attributes[0][0] ==
                               4);
                    }
                    assert(!adapter.encodingCommands &&
                           pg->compressed_attrs == 0x1234);
                    for (unsigned i = 0; i < 16; i++)
                        assert(!memcmp(before[i],
                                       pg->vertex_attributes[i].inline_value,
                                       16));
                    assert(kind ||
                           pg->vertex_attributes[0].inline_buffer_populated);
                    positions[1][0] = 4;
                    if (kind)
                        memcpy(pg->inline_array, positions, sizeof(positions));
                    b = compact ?
                            [adapter
                                encodeIndependentSnapshotsWithPrefixes:@[ @1 ]
                                                                 error:&error] :
                            [adapter
                                encodeIndependentSnapshotsWithError:&error];
                    require(b != nil, error);
                    retries++;
                }
                require([adapter submitWithError:&error], error);
                producer = adapter.encodingCommands;
                require([producer waitForSubmission:producer.lastSubmitted
                                              error:&error],
                        error);
                for (unsigned i = 0; i < 16; i++)
                    assert(!memcmp(before[i],
                                   pg->vertex_attributes[i].inline_value, 16));
                require([adapter completeWithError:&error], error);
                assert(!adapter.encodingCommands && !pg->compressed_attrs &&
                       pg->vertex_attributes[0].inline_value[0] == 4 &&
                       pg->vertex_attributes[0].inline_value[1] == 5);
                assert(kind ||
                       !pg->vertex_attributes[0].inline_buffer_populated);
                assert(recording == surfaces.commands.commandBuffer &&
                       token == surfaces.recording && !token.cancelled &&
                       !token.submitted);
                const NV2AMetalProgramInput *v = values(b[0]);
                assert(v[compact ? 0 : 1].attributes[0][0] == 4 &&
                       v[compact ? 0 : 1].attributes[0][1] == 5);
                require([surfaces submitWithError:&error], error);
                require([surfaces waitUntilIdleWithError:&error], error);
                assert(token.submitted && !token.cancelled &&
                       *(uint32_t *)result.contents == value);
                cases++;
                assert(!fi_idle_waits);
                fi_observed_commands = nil;
            }
    for (unsigned indexed = 0; indexed < 2; indexed++) {
        dma_stream();
        PGRAPHState *pg = &state->pgraph;
        if (indexed) {
            pg->inline_elements_length = 2;
            pg->inline_elements[0] = 0;
            pg->inline_elements[1] = 1;
        } else {
            pg->draw_arrays_length = 1;
            pg->draw_arrays_count[0] = 2;
        }
        require([adapter encodeIndependentSnapshotsWithError:&error] != nil,
                error);
        fi_observed_commands = adapter.encodingCommands;
        assert(adapter.encodingCommands != surfaces.commands);
        assert(
            !nv2a_metal_try_cpu_access(surfaces.cpuAccessGuard, 1088, 32, YES));
        require([adapter completeWithError:&error], error);
        assert(pg->vertex_attributes[0].inline_value[0] == 1.25f);
        assert(!fi_idle_waits);
        fi_observed_commands = nil;
        groups++;
    }
    method_setImplementation(collect, (IMP)fi_original_collect);
    method_setImplementation(idle, (IMP)fi_original_idle);
    assert(cases == 24 && retries == 20);
    groups += cases;
    puts("Independent Fetch:24 full/compact "
         "snapshot/cancel/submitted-cancel/fetch-fault/Current-fault/"
         "collection-error cases,"
         "20 corrected retries;CPU source mutations isolated,Current "
         "publication deferred,"
         "unrelated recorded surface work preserved;Array/Elements use "
         "independent guarded reads;zero producer queue drains PASS");
}
#endif
