/* Producer -> Fetch -> XF in one native Metal4 recording.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_SHARED_FETCH_XF_H
#define TEST_METAL_SHARED_FETCH_XF_H
#import "hw/xbox/nv2a/pgraph/metal/vertex-fetch.h"
@interface SharedEpochCommands : NV2AMetalCommands
@property(nonatomic) unsigned begins, submits, waits;
@end
@implementation SharedEpochCommands
- (id<MTL4CommandBuffer>)beginWithError:(NSError **)error
{
    _begins++;
    return [super beginWithError:error];
}
- (BOOL)submitWithError:(NSError **)error
{
    _submits++;
    return [super submitWithError:error];
}
- (BOOL)waitUntilIdleWithError:(NSError **)error
{
    _waits++;
    return [super waitUntilIdleWithError:error];
}
@end
static void shared_copy(NV2AMetalCommands *commands, id<MTLBuffer> source,
                        id<MTLBuffer> destination)
{
    NSError *error = nil;
    require([commands addResource:source error:&error], error);
    require([commands addResource:destination error:&error], error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:source
             sourceOffset:0
                 toBuffer:destination
        destinationOffset:0
                     size:source.length];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
}
static void shared_fetch_xf_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    SharedEpochCommands *commands =
        [[SharedEpochCommands alloc] initWithDevice:device error:&error];
    NV2AMetalEpochExecutor *executor =
        [[NV2AMetalEpochExecutor alloc] initWithDevice:device error:&error];
    NV2AMetalVertexFetch *fetch =
        [[NV2AMetalVertexFetch alloc] initWithDevice:device error:&error];
    require(commands && executor && fetch, error);
    NV2AMetalProgramInput inputs[8] = { 0 };
    for (unsigned v = 0; v < 8; v++) {
        for (unsigned a = 0; a < 16; a++)
            for (unsigned k = 0; k < 4; k++)
                inputs[v].attributes[a][k] = v + a * .0625f + k * .015625f;
        inputs[v].attributes[0][3] = 1;
        inputs[v].attributes[1][0] = 0;
    }
    id<MTLBuffer> staging =
        [device newBufferWithBytes:inputs
                            length:sizeof(inputs)
                           options:MTLResourceStorageModeShared];
    id<MTLBuffer> gpu =
        [device newBufferWithLength:sizeof(inputs)
                            options:MTLResourceStorageModePrivate];
    NV2AMetalProgramInput zeros[8] = { 0 };
    id<MTLBuffer> poison =
        [device newBufferWithBytes:zeros
                            length:sizeof(zeros)
                           options:MTLResourceStorageModeShared];
    assert(staging && gpu && poison);
    NV2AMetalAttributeSource sources[16] = { 0 };
    for (unsigned a = 0; a < 16; a++) {
        sources[a].buffer = gpu;
        sources[a].offset = a * 16;
        sources[a].byteLength = gpu.length - a * 16;
        sources[a].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
        sources[a].count = 4;
        sources[a].stride = sizeof(inputs[0]);
    }
    const NSUInteger spans[][2] = { { 0, 8 }, { 2, 3 }, { 7, 1 }, { 8, 0 } };
    unsigned cases = 0, vertices = 0;
    for (unsigned version = 1; version <= 5; version++)
        for (unsigned programmed = 0; programmed < 2; programmed++) {
            NV2AMetalPGRAPHVertexState *state =
                [[NV2AMetalPGRAPHVertexState alloc]
                    initWithSnapshot:wire(version, programmed, 0)
                               error:&error];
            require(state != nil, error);
            NSData *snapshot = state.snapshotData;
            copyBuffer(commands, poison, gpu);
            unsigned begins = commands.begins, submits = commands.submits,
                     waits = commands.waits;
            id<MTL4CommandBuffer> recording = [commands beginWithError:&error];
            require(recording != nil, error);
            shared_copy(commands, staging, gpu);
            NV2AMetalFetchResult *decoded = [fetch encodeSources:sources
                                                           count:8
                                                     firstVertex:0
                                                         indices:nil
                                                     indexOffset:0
                                                       indexSize:0
                                                        commands:commands
                                                           error:&error];
            require(decoded != nil, error);
            NSMutableArray<NV2AMetalEpochEncoding *> *encoded =
                [NSMutableArray new];
            NSMutableArray<NV2AMetalEpochEncoding *> *compact =
                [NSMutableArray new];
            for (unsigned i = 0; i < 4; i++) {
                NV2AMetalEpochEncoding *e =
                    [executor encodeState:state
                          attributeBuffer:decoded.attributes
                                    first:spans[i][0]
                                    count:spans[i][1]
                                 commands:commands
                                    error:&error];
                require(e != nil, error);
                [encoded addObject:e];
                NV2AMetalEpochEncoding *small =
                    [executor encodeRasterState:state
                                attributeBuffer:decoded.attributes
                                          first:spans[i][0]
                                          count:spans[i][1]
                                       commands:commands
                                          error:&error];
                require(small != nil, error);
                NSError *pendingError = nil;
                NV2AMetalEpochResult *pending =
                    [small fixedResultForCommands:commands error:&pendingError];
                assert(programmed ? (!pending && pendingError) :
                                    (pending && !pendingError &&
                                     pending.vertexCount == spans[i][1]));
                if (!programmed) {
                    NV2AMetalCommands *foreign = [[NV2AMetalCommands alloc]
                        initWithDevice:device
                                 error:&pendingError];
                    require(foreign != nil, pendingError);
                    assert(![small fixedResultForCommands:foreign
                                                    error:&pendingError] &&
                           pendingError);
                    assert([small fixedResultForCommands:commands
                                                   error:NULL] == pending);
                }
                [compact addObject:small];
                if (programmed) {
                    id program = [small valueForKey:@"program"];
                    id<MTLBuffer> faults = [program valueForKey:@"raw"];
                    assert(faults.length == sizeof(uint32_t));
                    assert(![program valueForKey:@"context"]);
                    assert(
                        ![[e valueForKey:@"program"] valueForKey:@"context"]);
                }
                assert(commands.commandBuffer == recording &&
                       commands.begins == begins + 1 &&
                       commands.submits == submits && commands.waits == waits);
            }
            finish(commands);
            assert(commands.begins == begins + 1 &&
                   commands.submits == submits + 1 &&
                   commands.waits == waits + 1);
            assert(
                !memcmp(decoded.attributes.contents, inputs, sizeof(inputs)));
            for (unsigned v = 0; v < 8; v++)
                assert(!((const uint32_t *)decoded.faults.contents)[v]);
            for (unsigned i = 0; i < 4; i++) {
                NV2AMetalEpochResult *actual =
                    [encoded[i] resolveWithError:&error];
                NV2AMetalEpochResult *expected =
                    [executor executeState:state
                           attributeBuffer:decoded.attributes
                                     first:spans[i][0]
                                     count:spans[i][1]
                                     error:&error];
                NV2AMetalEpochResult *small =
                    [compact[i] resolveWithError:&error];
                require(actual && expected && small, error);
                assert(!small.registers &&
                       small.vertexCount == actual.vertexCount &&
                       [small.constants isEqual:actual.constants] &&
                       [small.written isEqual:actual.written]);
                if (small.vertexCount)
                    assert(!memcmp(
                        small.vertices.contents, actual.vertices.contents,
                        small.vertexCount * sizeof(NV2AMetalVertex)));
                else
                    assert(!small.vertices);
                NSUInteger count = spans[i][1];
                assert(actual.vertexCount == count &&
                       [actual.constants isEqual:expected.constants] &&
                       [actual.written isEqual:expected.written]);
                if (count) {
                    assert(!memcmp(actual.registers.contents,
                                   expected.registers.contents,
                                   count * sizeof(NV2AMetalProgramOutput)));
                    assert(!memcmp(actual.vertices.contents,
                                   expected.vertices.contents,
                                   count * sizeof(NV2AMetalVertex)));
                    if (programmed)
                        for (NSUInteger v = 0; v < count; v++)
                            assert(!memcmp(
                                ((const NV2AMetalProgramOutput *)
                                     actual.registers.contents)[v]
                                    .registers[0],
                                inputs[spans[i][0] + v].attributes[0], 16));
                } else
                    assert(!actual.registers && !actual.vertices);
                vertices += count;
                cases++;
            }
            assert([state.snapshotData isEqual:snapshot]);
        }
    /* Only the recording/encoding retain GPU resources after the producer
     * object and its source capture leave this autorelease pool. */
    NV2AMetalWritableEncoding *retainedEncoding = nil;
    require([commands beginWithError:&error] != nil, error);
    @autoreleasepool {
        NV2AMetalWritableProgram *temporary =
            [[NV2AMetalWritableProgram alloc] initWithDevice:device
                                                       error:&error];
        NV2AMetalPGRAPHVertexState *temporaryState =
            [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:wire(5, 1, 0)
                                                           error:&error];
        require(temporary && temporaryState, error);
        NV2AMetalProgramUniforms u = temporaryState.programUniforms;
        retainedEncoding =
            [temporary encodeTokens:temporaryState.programBytes.bytes
                             length:temporaryState.programBytes.length / 16
                           uniforms:&u
                    attributeBuffer:staging
                              first:2
                              count:3
                             access:0
                        writeEnable:NO
                          rasterize:YES
                           commands:commands
                              error:&error];
        require(retainedEncoding != nil, error);
    }
    finish(commands);
    NV2AMetalWritableResult *retained =
        [retainedEncoding resolveWithError:&error];
    require(retained != nil, error);
    for (unsigned v = 0; v < 3; v++)
        assert(!memcmp(
            ((const NV2AMetalProgramOutput *)retained.registers.contents)[v]
                .registers[0],
            inputs[2 + v].attributes[0], 16));
    NSMutableData *faultWire = [wire(5, 1, 0) mutableCopy];
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
    [faultWire replaceBytesInRange:NSMakeRange(faultWire.length - bytes.length,
                                               bytes.length)
                         withBytes:bytes.bytes];
    uint32_t dynamicFlags = 3;
    NSMutableData *flagBytes = [NSMutableData new];
    append(flagBytes, &dynamicFlags, sizeof(dynamicFlags));
    [faultWire replaceBytesInRange:NSMakeRange(8, 4) withBytes:flagBytes.bytes];
    NV2AMetalPGRAPHVertexState *faultState =
        [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:faultWire
                                                       error:&error];
    require(faultState != nil, error);
    inputs[7].attributes[1][0] = 1000;
    memcpy(staging.contents, inputs, sizeof(inputs));
    require([commands beginWithError:&error] != nil, error);
    shared_copy(commands, staging, gpu);
    NV2AMetalFetchResult *decoded = [fetch encodeSources:sources
                                                   count:8
                                             firstVertex:0
                                                 indices:nil
                                             indexOffset:0
                                               indexSize:0
                                                commands:commands
                                                   error:&error];
    require(decoded != nil, error);
    NV2AMetalEpochEncoding *bad = [executor encodeState:faultState
                                        attributeBuffer:decoded.attributes
                                                  first:0
                                                  count:8
                                               commands:commands
                                                  error:&error];
    require(bad != nil, error);
    finish(commands);
    error = nil;
    assert(![bad resolveWithError:&error] && error);
    for (unsigned test = 0; test < 4; test++) {
        inputs[0].attributes[1][0] = inputs[3].attributes[1][0] =
            inputs[7].attributes[1][0] = 0;
        if (test < 3)
            inputs[(unsigned[]){ 0, 3, 7 }[test]].attributes[1][0] = 1000;
        memcpy(staging.contents, inputs, sizeof(inputs));
        require([commands beginWithError:&error] != nil, error);
        shared_copy(commands, staging, gpu);
        NV2AMetalEpochEncoding *full = [executor encodeState:faultState
                                             attributeBuffer:gpu
                                                       first:0
                                                       count:8
                                                    commands:commands
                                                       error:&error];
        NV2AMetalEpochEncoding *small = [executor encodeRasterState:faultState
                                                    attributeBuffer:gpu
                                                              first:0
                                                              count:8
                                                           commands:commands
                                                              error:&error];
        require(full && small, error);
        finish(commands);
        NSError *fullError = nil, *smallError = nil;
        NV2AMetalEpochResult *f = [full resolveWithError:&fullError];
        NV2AMetalEpochResult *c = [small resolveWithError:&smallError];
        if (test < 3) {
            assert(!f && !c &&
                   [fullError.localizedDescription
                       isEqual:smallError.localizedDescription]);
        } else {
            require(f && c, smallError);
            assert(!c.registers &&
                   !memcmp(c.vertices.contents, f.vertices.contents,
                           8 * sizeof(NV2AMetalVertex)));
        }
    }
    NV2AMetalPGRAPHVertexState *writable =
        [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:wire(5, 1, 2)
                                                       error:&error];
    require(writable && writable.writeEnable, error);
    require([commands beginWithError:&error] != nil, error);
    error = nil;
    assert(![executor encodeState:writable
                  attributeBuffer:decoded.attributes
                            first:0
                            count:8
                         commands:commands
                            error:&error] &&
           error);
    error = nil;
    assert(![executor encodeRasterState:writable
                        attributeBuffer:decoded.attributes
                                  first:0
                                  count:8
                               commands:commands
                                  error:&error] &&
           error);
    [commands cancel];
    puts(
        "Compact XF:40 byte-exact fixed/readonly epochs/120 vertices, nil raw "
        "outputs, "
         "one 4-byte programmable fault summary and no readonly context buffers; "
        "first/middle/last "
        "fault parity, successful retry and writable rejection PASS");
    printf("Shared native recording: %u exact epochs/%u vertices, "
           "producer+fetch+XF "
           "one submit/wait, v1-v5 fixed/readonly, suffix/empty, later fault "
           "and writable exclusion PASS\n",
           cases, vertices);
}
#endif
