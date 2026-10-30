/* Real PGRAPH retries with immutable offset/fragmented vertex transport.
 * No emulator, BIOS or window. SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_DRAW_TRANSPORT_H
#define TEST_METAL_DRAW_TRANSPORT_H
#import "hw/xbox/nv2a/pgraph/metal/archive-native.h"
#import "hw/xbox/nv2a/pgraph/metal/pending-native.h"

static BOOL transport_reference, transport_encoding;
static NV2AMetalCommands *transport_relocation_commands;

static unsigned transport_encoders, transport_copies, transport_transforms;
static uint64_t transport_bytes;
static NSArray<NV2AMetalVertexSlice *> *transport_views;
static id (*transport_original_compute)(id, SEL);
static void (*transport_original_copy)(id, SEL, id<MTLBuffer>, NSUInteger,
                                       id<MTLBuffer>, NSUInteger, NSUInteger);
static NSArray *(*transport_original_native)(id, SEL, NV2AMetalCommands *,
                                             NSError **);
static NSArray *(*transport_original_geometry)(
    id, SEL, id<MTLBuffer>, NSUInteger, NSUInteger, enum NV2AMetalPrimitive,
    const NV2AMetalGeometryRasterConfig *, BOOL, BOOL, BOOL,
    NV2AMetalCommands *, NSError **);
static NV2AMetalEpochEncoding *(*transport_original_transform)(
    id, SEL, NV2AMetalPGRAPHVertexState *, id<MTLBuffer>, NSUInteger,
    NSUInteger, NV2AMetalCommands *, NSError **);

static NV2AMetalEpochResult *(*transport_original_execute)(
    id, SEL, NV2AMetalPGRAPHVertexState *, id<MTLBuffer>, NSUInteger,
    NSUInteger, NSError **);
static NV2AMetalEpochResult *
transport_execute(id owner, SEL selector, NV2AMetalPGRAPHVertexState *captured,
                  id<MTLBuffer> input, NSUInteger first, NSUInteger count,
                  NSError **error)
{
    transport_transforms++;
    return transport_original_execute(owner, selector, captured, input, first,
                                      count, error);
}
static id transport_compute(id owner, SEL selector)
{
    transport_encoders += transport_encoding;
    return transport_original_compute(owner, selector);
}
static void transport_copy(id owner, SEL selector, id<MTLBuffer> source,
                           NSUInteger sourceOffset, id<MTLBuffer> destination,
                           NSUInteger destinationOffset, NSUInteger size)
{
    if (transport_encoding) {
        transport_copies++;
        transport_bytes += size;
    }
    transport_original_copy(owner, selector, source, sourceOffset, destination,
                            destinationOffset, size);
}
static NSArray *transport_native(id owner, SEL selector,
                                 NV2AMetalCommands *commands, NSError **error)
{
    transport_encoding = YES;
    NSArray *result;
    if (transport_reference) {
        /* Exercise the previous production adapter, then express its offset0
         * buffers as views so the remaining controller is identical. */
        NSArray<id<MTLBuffer>> *joined =
            [(NV2AMetalPendingNative *)owner encodeWithCommands:commands
                                                          error:error];
        if (!joined) {
            transport_encoding = NO;
            return nil;
        }
        NSMutableArray *views = [NSMutableArray new];
        NSArray<NSNumber *> *counts = [owner counts];
        for (NSUInteger i = 0; i < joined.count; i++) {
            NV2AMetalVertexStream *stream = [[NV2AMetalVertexStream alloc]
                initWithDevice:commands.device
                         limit:counts[i].unsignedIntegerValue
                         error:error];
            if (!stream ||
                ![stream appendVertices:joined[i]
                                  first:0
                                  count:counts[i].unsignedIntegerValue
                                  error:error]) {
                transport_encoding = NO;
                return nil;
            }
            NV2AMetalVertexSlice *view =
                [stream encodeSliceForDrawingWithCommands:commands error:error];
            if (!view) {
                transport_encoding = NO;
                return nil;
            }
            [views addObject:view];
        }
        result = views;
    } else {
        result = transport_original_native(owner, selector, commands, error);
    }
    transport_encoding = NO;
    transport_views = result;
    return result;
}
static NSArray *transport_geometry(
    id owner, SEL selector, id<MTLBuffer> vertices, NSUInteger first,
    NSUInteger count, enum NV2AMetalPrimitive primitive,
    const NV2AMetalGeometryRasterConfig *config, BOOL smooth, BOOL provoking,
    BOOL perspective, NV2AMetalCommands *commands, NSError **error)
{
    assert(transport_views.count == 1);
    NV2AMetalVertexSlice *view = transport_views[0];
    assert(vertices == view.buffer && first == view.firstVertex &&
           count == view.vertexCount);
    return transport_original_geometry(owner, selector, vertices, first, count,
                                       primitive, config, smooth, provoking,
                                       perspective, commands, error);
}
static NV2AMetalEpochEncoding *
transport_transform(id owner, SEL selector,
                    NV2AMetalPGRAPHVertexState *captured, id<MTLBuffer> input,
                    NSUInteger first, NSUInteger count,
                    NV2AMetalCommands *commands, NSError **error)
{
    transport_transforms++;
    return transport_original_transform(owner, selector, captured, input, first,
                                        count, commands, error);
}
static NV2AMetalEpochEncoding *(*transport_original_serial)(
    id, SEL, NV2AMetalPGRAPHVertexState *, id<MTLBuffer>, NSUInteger,
    NSUInteger, NV2AMetalEpochEncoding *, NV2AMetalCommands *, NSError **);
static NV2AMetalEpochEncoding *
transport_serial(id owner, SEL selector, NV2AMetalPGRAPHVertexState *captured,
                 id<MTLBuffer> input, NSUInteger first, NSUInteger count,
                 NV2AMetalEpochEncoding *previous, NV2AMetalCommands *commands,
                 NSError **error)
{
    transport_transforms++;
    return transport_original_serial(owner, selector, captured, input, first,
                                     count, previous, commands, error);
}
static NV2AMetalPendingInput *transport_prefix(NV2AMetalPendingInput *input,
                                               NSUInteger count)
{
    if (input.kind == NV2AMetalInputArrays)
        return [NV2AMetalPendingInput arraysFrom:input.first count:count];
    if (input.kind == NV2AMetalInputIndexed)
        return [NV2AMetalPendingInput
            indexed:[input.indices subdataWithRange:NSMakeRange(0, count * 4)]];
    return [NV2AMetalPendingInput inlineKind:input.kind count:count];
}
static NV2AMetalPendingJournal *transport_relocate(NV2AMetalPendingJournal *old,
                                                   unsigned layout,
                                                   id<MTLBuffer> *sourceOwner)
{
    NSError *error = nil;
    assert(old.retainedInputs.count == 1 && old.retainedStreams.count == 1 &&
           old.retainedStreams[0].count == 1);
    NV2AMetalPendingInput *input = old.retainedInputs[0];
    NV2AMetalPendingSpan *source = old.retainedStreams[0][0];
    assert(source.count == input.count && input.count == (layout == 6 ? 3 : 6));
    NV2AMetalCommands *commands = transport_relocation_commands;
    id<MTLBuffer> buffers[2];
    for (unsigned i = 0; i < 2; i++) {
        buffers[i] =
            [commands.device newBufferWithLength:16 * sizeof(NV2AMetalVertex)
                                         options:MTLResourceStorageModePrivate];
        assert(buffers[i]);
    }
    require([commands beginWithError:&error] != nil, error);
    require([commands addResource:buffers[0] error:&error] &&
                [commands addResource:buffers[1] error:&error] &&
                [commands addResource:source.resource error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    for (unsigned i = 0; i < 2; i++)
        [e fillBuffer:buffers[i]
                range:NSMakeRange(0, buffers[i].length)
                value:0xcd];
    [e endEncoding];
    e = [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    unsigned parts = layout >= 2 && layout <= 5 ? 2 : 1;
    NSUInteger firsts[2] = { layout == 0 ? 0 :
                             layout == 4 ? 9 :
                                           3,
                             layout == 2 ? 6 :
                             layout == 3 ? 9 :
                                           3 };
    for (unsigned i = 0; i < parts; i++)
        [e copyFromBuffer:source.resource
                 sourceOffset:(source.first + i * 3) * sizeof(NV2AMetalVertex)
                     toBuffer:buffers[layout == 5 ? i : 0]
            destinationOffset:firsts[i] * sizeof(NV2AMetalVertex)
                         size:(parts == 1 ? source.count : 3) *
                              sizeof(NV2AMetalVertex)];
    [e endEncoding];
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    NV2AMetalPendingJournal *journal =
        [[NV2AMetalPendingJournal alloc] initWithLimit:64];
    for (unsigned i = 0; i < parts; i++) {
        NSUInteger count = parts == 1 ? source.count : 3;
        NV2AMetalPendingInput *prefix =
            transport_prefix(input, parts == 1 ? count : (i + 1) * count);
        NV2AMetalPendingPlan *plan = [journal planInputs:@[ prefix ]
                                     preservingLastArray:YES
                                                   error:&error];
        NV2AMetalPendingSpan *span =
            [NV2AMetalPendingSpan resource:buffers[layout == 5 ? i : 0]
                                     first:firsts[i]
                                     count:count];
        NV2AMetalPendingUpdate *update = plan && span ?
                                             [journal preparePlan:plan
                                                         suffixes:@[ span ]
                                                            error:&error] :
                                             nil;
        require(update && [journal commitUpdate:update error:&error], error);
    }
    *sourceOwner = buffers[0];
    return journal;
}
static unsigned transport_check_padding(NSArray<NV2AMetalPendingSpan *> *spans,
                                        NSData *vertices)
{
    NSError *error = nil;
    NV2AMetalCommands *commands = transport_relocation_commands;
    NSMutableArray<id<MTLBuffer>> *owners = [NSMutableArray new];
    NSMutableArray<id<MTLBuffer>> *readbacks = [NSMutableArray new];
    NSMutableArray<NSMutableData *> *expected = [NSMutableArray new];
    for (NV2AMetalPendingSpan *span in spans)
        if (![owners containsObject:span.resource])
            [owners addObject:span.resource];
    require([commands beginWithError:&error] != nil, error);
    for (id<MTLBuffer> owner in owners) {
        NSMutableData *bytes = [NSMutableData dataWithLength:owner.length];
        memset(bytes.mutableBytes, 0xcd, bytes.length);
        NSUInteger offset = 0;
        for (NV2AMetalPendingSpan *span in spans) {
            NSUInteger size = span.count * sizeof(NV2AMetalVertex);
            assert(size <= vertices.length - offset);
            if (span.resource == owner)
                memcpy((uint8_t *)bytes.mutableBytes +
                           span.first * sizeof(NV2AMetalVertex),
                       (const uint8_t *)vertices.bytes + offset, size);
            offset += size;
        }
        assert(offset == vertices.length);
        id<MTLBuffer> readback =
            [commands.device newBufferWithLength:owner.length
                                         options:MTLResourceStorageModeShared];
        assert(readback);
        require([commands addResource:owner error:&error] &&
                    [commands addResource:readback error:&error],
                error);
        [expected addObject:bytes];
        [readbacks addObject:readback];
    }
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    for (NSUInteger i = 0; i < owners.count; i++)
        [encoder copyFromBuffer:owners[i]
                   sourceOffset:0
                       toBuffer:readbacks[i]
              destinationOffset:0
                           size:owners[i].length];
    [encoder endEncoding];
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    for (NSUInteger i = 0; i < owners.count; i++)
        assert(!memcmp(readbacks[i].contents, expected[i].bytes,
                       expected[i].length));
    return (unsigned)owners.count;
}
static unsigned transport_relocated_streams;
static NV2AMetalPendingSpan *transport_relocate_span(NV2AMetalPendingSpan *span)
{
    /* Readonly publication may precede GPU completion. Queue relocation after
     * that producer and before geometry, preserving its transaction/barriers.
     */
    NSError *error = nil;
    NV2AMetalCommands *commands = surfaces.cache.commands;
    id<MTLBuffer> buffer = [commands.device
        newBufferWithLength:(span.count + 6) * sizeof(NV2AMetalVertex)
                    options:MTLResourceStorageModePrivate];
    assert(buffer);
    assert(commands.commandBuffer);
    require([commands addResource:span.resource error:&error] &&
                [commands addResource:buffer error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:span.resource
             sourceOffset:span.first * sizeof(NV2AMetalVertex)
                 toBuffer:buffer
        destinationOffset:3 * sizeof(NV2AMetalVertex)
                     size:span.count * sizeof(NV2AMetalVertex)];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    transport_relocated_streams++;
    return [NV2AMetalPendingSpan resource:buffer first:3 count:span.count];
}
static void draw_transport_tests(void)
{
    NSError *error = nil;
    transport_relocation_commands =
        [[NV2AMetalCommands alloc] initWithDevice:surfaces.cache.commands.device
                                            error:&error];
    require(transport_relocation_commands != nil, error);
    unsigned pairs = 0, archives = 0, zeroCopies = 0, joins = 0,
             paddingChecks = 0;
    uint64_t avoided = 0, samples = 0;
    Method native =
        class_getInstanceMethod(NV2AMetalPendingNative.class,
                                @selector(encodeSlicesWithCommands:error:));
    Method geometryMethod = class_getInstanceMethod(
        NV2AMetalGeometry.class,
        @selector(encodeNativeRasterVertices:first:count:primitive:config:
                  smooth:firstProvoking:zPerspective:commands:error:));
    Method transform = class_getInstanceMethod(
        NV2AMetalEpochExecutor.class,
        @selector(
            encodeRasterState:attributeBuffer:first:count:commands:error:));
    Method execute = class_getInstanceMethod(
        NV2AMetalEpochExecutor.class,
        @selector(executeRasterState:attributeBuffer:first:count:error:));
    Method serial = class_getInstanceMethod(
        NV2AMetalEpochExecutor.class,
        @selector(encodeSerialRasterState:attributeBuffer:first:count:previous:
                  commands:error:));
    assert(native && geometryMethod && transform && execute && serial);
    transport_original_serial =
        (void *)method_setImplementation(serial, (IMP)transport_serial);
    transport_original_execute =
        (void *)method_setImplementation(execute, (IMP)transport_execute);
    transport_original_transform =
        (void *)method_setImplementation(transform, (IMP)transport_transform);
    NV2AMetalCommands *commands = transport_relocation_commands;
    require([commands beginWithError:&error] != nil, error);
    Class commandClass = object_getClass(commands.commandBuffer);
    SEL computeSelector = @selector(computeCommandEncoder);
    Method compute = class_getInstanceMethod(commandClass, computeSelector);
    assert(compute);
    class_addMethod(commandClass, computeSelector,
                    method_getImplementation(compute),
                    method_getTypeEncoding(compute));
    compute = class_getInstanceMethod(commandClass, computeSelector);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    Class encoderClass = object_getClass(encoder);
    SEL copySelector =
        @selector(copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:);
    Method copy = class_getInstanceMethod(encoderClass, copySelector);
    assert(copy);
    class_addMethod(encoderClass, copySelector, method_getImplementation(copy),
                    method_getTypeEncoding(copy));
    copy = class_getInstanceMethod(encoderClass, copySelector);
    [encoder endEncoding];
    [commands cancel];
    transport_original_compute =
        (void *)method_setImplementation(compute, (IMP)transport_compute);
    transport_original_copy =
        (void *)method_setImplementation(copy, (IMP)transport_copy);
    for (unsigned mode = 0; mode < 3; mode++)
        for (unsigned kind = 0; kind < 4; kind++)
            for (unsigned primitive = 1; primitive <= 10; primitive++)
                for (unsigned layout = 0; layout < 7; layout++) {
                    uint8_t expected[512];
                    float current[2][4];
                    uint32_t expectedQuery = 0;
                    uint64_t referenceBytes = 0;
                    for (unsigned reference = 0; reference < 2; reference++) {
                        @autoreleasepool {
                            stream_scene(0,
                                         (primitive + mode + kind + layout) % 4,
                                         mode != 0, 1);
                            PGRAPHState *pg = &state->pgraph;
                            pg->primitive_mode = primitive;
                            pg->enable_vertex_program_write = mode == 2;
                            if (kind) {
                                pg->draw_arrays_length = 0;
                                if (kind == 1) {
                                    pg->inline_elements_length = 6;
                                    for (unsigned i = 0; i < 6; i++)
                                        pg->inline_elements[i] = i;
                                } else if (kind == 2) {
                                    pg->inline_buffer_length = 6;
                                    pg->vertex_attributes[0].inline_buffer =
                                        (float *)(state->vram_ptr + 16384);
                                    pg->vertex_attributes[3].inline_buffer =
                                        (float *)(state->vram_ptr + 20480);
                                    pg->vertex_attributes[0]
                                        .inline_buffer_populated = true;
                                    pg->vertex_attributes[3]
                                        .inline_buffer_populated = true;
                                } else {
                                    pg->inline_array_length = 48;
                                    for (unsigned i = 0; i < 6; i++) {
                                        memcpy(pg->inline_array + i * 8,
                                               state->vram_ptr + 16384 + i * 16,
                                               16);
                                        memcpy(pg->inline_array + i * 8 + 4,
                                               state->vram_ptr + 20480 + i * 16,
                                               16);
                                    }
                                }
                            }
                            unsigned initialCount = layout == 6 ? 3 : 6;
                            if (!kind)
                                pg->draw_arrays_count[0] = initialCount;
                            if (kind == 1)
                                pg->inline_elements_length = initialCount;
                            if (kind == 2)
                                pg->inline_buffer_length = initialCount;
                            if (kind == 3)
                                pg->inline_array_length = initialCount * 8;
                            qemu_mutex_lock(&pg->lock);
                            require([draw beginWithError:&error], error);
                            transport_transforms = 0;
                            error = nil;
                            assert(!injected_draw_failure(YES, &error) &&
                                   error);
                            if (transport_transforms != 1 ||
                                surfaces.cache.commands.commandBuffer ||
                                pg->draw_time) {
                                fprintf(stderr,
                                        "Transport initial mode%u kind%u "
                                        "primitive%u layout%u reference%u: "
                                        "transforms%u recording%d time%lld\n",
                                        mode, kind, primitive, layout,
                                        reference, transport_transforms,
                                        surfaces.cache.commands.commandBuffer !=
                                            nil,
                                        (long long)pg->draw_time);
                                abort();
                            }
                            error = nil;
                            if (!mode) {
                                /* The rejected known-Current Fixed raster
                                 * transaction discarded its unsubmitted vertex
                                 * buffers. Relocation needs an explicit
                                 * completed XF boundary, rather than reading
                                 * those bytes. */
                                NV2AMetalPendingJournal *aborted =
                                    [draw valueForKey:@"pending"];
                                assert(!aborted.streamCount);
                                require([draw prepareVertexStateChangeWithError:
                                                  &error],
                                        error);
                            }
                            /* Direct archive/relocation on a private test
                             * queue requires completion of any accepted GPU
                             * producer, including the no-wait readonly path. */
                            require([surfaces.cache submitWithError:&error] &&
                                        [surfaces.cache
                                            waitUntilIdleWithError:&error],
                                    error);
                            unsigned completedTransforms = transport_transforms;
                            NV2AMetalPendingJournal *old =
                                [draw valueForKey:@"pending"];
                            NV2AMetalPendingArchive *before =
                                nv2a_metal_pending_capture(old, commands,
                                                           &error);
                            require(before != nil, error);
                            id<MTLBuffer> source;
                            NV2AMetalPendingJournal *journal =
                                transport_relocate(old, layout, &source);
                            NV2AMetalPendingArchive *after =
                                nv2a_metal_pending_capture(journal, commands,
                                                           &error);
                            require(after != nil, error);
                            assert([before.data isEqualToData:after.data]);
                            archives++;
                            if (!(primitive % 3) && layout == kind) {
                                NV2AMetalPendingJournal *restored =
                                    nv2a_metal_pending_restore(after, commands,
                                                               64, &error);
                                require(restored != nil, error);
                                NV2AMetalPendingArchive *again =
                                    nv2a_metal_pending_capture(
                                        restored, commands, &error);
                                require(again != nil, error);
                                assert([again.data isEqualToData:after.data]);
                                archives++;
                            }
                            NSArray<NV2AMetalPendingSpan *> *paddedSpans =
                                journal.retainedStreams[0];
                            [draw setValue:journal forKey:@"pending"];
                            if (!kind)
                                pg->draw_arrays_count[0] = 6;
                            if (kind == 1)
                                pg->inline_elements_length = 6;
                            if (kind == 2)
                                pg->inline_buffer_length = 6;
                            if (kind == 3)
                                pg->inline_array_length = 48;
                            transport_reference = reference == 0;
                            transport_encoders = transport_copies = 0;
                            transport_bytes = 0;
                            transport_views = nil;
                            transport_original_native =
                                (void *)method_setImplementation(
                                    native, (IMP)transport_native);
                            transport_original_geometry =
                                (void *)method_setImplementation(
                                    geometryMethod, (IMP)transport_geometry);
                            require([draw endWithError:&error], error);
                            draws++;
                            method_setImplementation(
                                native, (IMP)transport_original_native);
                            method_setImplementation(
                                geometryMethod,
                                (IMP)transport_original_geometry);
                            assert(transport_transforms ==
                                   completedTransforms +
                                       (layout == 6 ? 1u : 0u));
                            assert(transport_views.count == 1 &&
                                   transport_views[0].vertexCount == 6);
                            BOOL borrowed = reference && layout <= 2;
                            BOOL joined = !borrowed && layout != 0;
                            assert(transport_encoders == (unsigned)joined);
                            assert(transport_bytes ==
                                   (joined ? 6 * sizeof(NV2AMetalVertex) : 0));
                            assert(transport_copies ==
                                   (joined ? (layout <= 2 ? 1u : 2u) : 0u));
                            assert(transport_views[0].firstVertex ==
                                   (borrowed && layout ? 3u : 0u));
                            assert((transport_views[0].buffer == source) ==
                                   !joined);
                            assert(pg->draw_time == 1 &&
                                   !surfaces.cache.commands.commandBuffer);
                            qemu_mutex_unlock(&pg->lock);
                            uint32_t query = stream_report();
                            paddingChecks += transport_check_padding(
                                paddedSpans, before.vertices[0]);
                            read_vram(1024, 256);
                            read_vram(4096, 256);
                            if (!reference) {
                                memcpy(expected, state->vram_ptr + 1024, 256);
                                memcpy(expected + 256, state->vram_ptr + 4096,
                                       256);
                                memcpy(current[0],
                                       pg->vertex_attributes[0].inline_value,
                                       16);
                                memcpy(current[1],
                                       pg->vertex_attributes[3].inline_value,
                                       16);
                                expectedQuery = query;
                                referenceBytes = transport_bytes;
                            } else {
                                assert(!memcmp(expected, state->vram_ptr + 1024,
                                               256));
                                assert(!memcmp(expected + 256,
                                               state->vram_ptr + 4096, 256));
                                assert(!memcmp(
                                    current[0],
                                    pg->vertex_attributes[0].inline_value, 16));
                                assert(!memcmp(
                                    current[1],
                                    pg->vertex_attributes[3].inline_value, 16));
                                assert(query == expectedQuery);
                                samples += query;
                                pairs++;
                                zeroCopies += !joined;
                                joins += joined;
                                assert(referenceBytes >= transport_bytes);
                                avoided += referenceBytes - transport_bytes;
                            }
                            transport_views = nil;
                        }
                    }
                }
    method_setImplementation(compute, (IMP)transport_original_compute);
    method_setImplementation(copy, (IMP)transport_original_copy);
    method_setImplementation(transform, (IMP)transport_original_transform);
    method_setImplementation(execute, (IMP)transport_original_execute);
    method_setImplementation(serial, (IMP)transport_original_serial);
    assert(pairs == 840 && zeroCopies == 360 && joins == 480 &&
           archives == 1752 && paddingChecks == 1920 && samples);
    printf("PGRAPH vertex transport:840 exact "
           "color/depth-stencil/Current/query pairs;all10 topologies/four "
           "input kinds/Fixed-Readonly-Writable/seven layouts;360 "
           "zero-copy/480 joined draws,351360 actual join bytes avoided;1752 "
           "canonical snapshot/restore comparisons;geometry buffer/first/count "
           "identity,1920 exact full padded-buffer checks and1680 "
           "failure/retries with "
           "no XF replay,120 suffix epoch pairs;%llu counted samples PASS\n",
           (unsigned long long)samples);
    assert(avoided == 351360);
    groups++;

    require(transport_relocation_commands != nil, error);
    transport_relocated_streams = 0;
    stream_relocate_span = transport_relocate_span;
    stream_group_contract_tests();
    stream_relocate_span = NULL;
    transport_relocation_commands = nil;
    assert(transport_relocated_streams > 1000);
    printf("PGRAPH offset3 independent streams:64 exact grouped/separate "
           "image/Current/query pairs,eight independent ranges,four "
           "late-failure/retries,%u GPU spans relocated in producer order and "
           "exact "
           "geometry input offsets PASS\n",
           transport_relocated_streams);
}
#endif
