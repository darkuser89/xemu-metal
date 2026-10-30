/* Native capture epochs, private GPU inputs, no app/window.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "hw/xbox/nv2a/pgraph/metal/vertex-epoch.h"
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include "test-metal-vertex-capture.h"
#include "test-metal-vertex-context.h"
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Epoch executor native: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static void finish(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
}
static void copyBuffer(NV2AMetalCommands *commands, id<MTLBuffer> from,
                       id<MTLBuffer> to)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    require([commands addResource:from error:&error], error);
    require([commands addResource:to error:&error], error);
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromBuffer:from
               sourceOffset:0
                   toBuffer:to
          destinationOffset:0
                       size:from.length];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    finish(commands);
}
static NSData *wire(unsigned version, unsigned programmed, unsigned policy)
{
    NSMutableData *data = [capture(version, programmed, 0) mutableCopy];
    if (version == 5) {
        uint32_t flags = programmed | (policy << 4);
        NSMutableData *raw = [NSMutableData new];
        append(raw, &flags, 4);
        [data replaceBytesInRange:NSMakeRange(8, 4) withBytes:raw.bytes];
    }
    if (programmed) {
        Token tokens[3] = { token(1, 0, 96), token(1, 0, 96),
                            token(1, 0, 191) };
        source(&tokens[0], 0, 2, 0, 0xe4);
        destination(&tokens[0], 0x170, 15, 0, 0, 0, 0);
        tokens[1].word[1] |= 1u << 9;
        source(&tokens[1], 0, 2, 0, 0xe4);
        destination(&tokens[1], 191, 15, 0, 0, 0, 0);
        source(&tokens[2], 0, 3, 0, 0xe4);
        destination(&tokens[2], 0x179, 15, 0, 0, 0, 0);
        tokens[2].word[3] |= 1;
        /* Legacy captures forbid constant writes, retain vertex-only aliases.
         */
        if (version < 5)
            destination(&tokens[1], 0x17a, 15, 0, 0, 0, 0);
        uint32_t slots = 3;
        NSMutableData *raw = [NSMutableData new];
        append(raw, &slots, 4);
        [data replaceBytesInRange:NSMakeRange(28, 4) withBytes:raw.bytes];
        [data setLength:data.length - 16];
        raw = [NSMutableData new];
        append(raw, tokens, sizeof(tokens));
        [data appendData:raw];
    }
    return data;
}
static void raw_fixed_epoch_tests(NV2AMetalCommands *commands,
                                  NV2AMetalEpochExecutor *executor)
{
    PGRAPHState *pg = calloc(1, sizeof(*pg));
    PGRAPHState *before = malloc(sizeof(*before));
    assert(pg && before);
    NV2AMetalProgramInput inputs[6] = { 0 };
    for (unsigned v = 0; v < 6; v++) {
        inputs[v].attributes[0][0] = v + 1;
        inputs[v].attributes[0][1] = inputs[v].attributes[0][2] = 2;
        inputs[v].attributes[0][3] = 1;
        inputs[v].attributes[2][2] = 1;
        for (unsigned a = 3; a < 13; a++)
            for (unsigned k = 0; k < 4; k++)
                inputs[v].attributes[a][k] = .05f * a + .01f * k;
    }
    id<MTLBuffer> staging =
        [commands.device newBufferWithBytes:inputs
                                     length:sizeof(inputs)
                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> gpu =
        [commands.device newBufferWithLength:sizeof(inputs)
                                     options:MTLResourceStorageModePrivate];
    assert(staging && gpu);
    copyBuffer(commands, staging, gpu);
    unsigned cases = 0;
    for (unsigned lighting = 0; lighting < 2; lighting++)
        for (unsigned normalize = 0; normalize < 2; normalize++)
            for (unsigned two = 0; two < 2; two++)
                for (unsigned point = 0; point < 2; point++)
                    for (unsigned fog = 0; fog < 4; fog++) {
                        memset(pg, 0, sizeof(*pg));
                        pg->surface_scale_factor = 2;
                        pg->surface_binding_dim.width =
                            pg->surface_binding_dim.height = 4;
                        pg->surface_shape.zeta_format =
                            NV097_SET_SURFACE_FORMAT_ZETA_Z16;
                        pg->regs_[NV_PGRAPH_POINTSIZE] = 24;
                        pg->regs_[NV_PGRAPH_CSV0_C] =
                            (lighting ? NV_PGRAPH_CSV0_C_LIGHTING : 0) |
                            (normalize ? NV_PGRAPH_CSV0_C_NORMALIZATION_ENABLE :
                                         0) |
                            (two ? NV_PGRAPH_CSV0_C_TWO_SIDE : 0);
                        pg->regs_[NV_PGRAPH_CSV0_D] =
                            point ? NV_PGRAPH_CSV0_D_POINTPARAMSENABLE : 0;
                        pg->regs_[NV_PGRAPH_CONTROL_3] =
                            fog ? NV_PGRAPH_CONTROL_3_FOGENABLE : 0;
                        SET_MASK(pg->regs_[NV_PGRAPH_CONTROL_3],
                                 NV_PGRAPH_CONTROL_3_FOG_MODE,
                                 fog == 3 ? 5 :
                                 fog == 2 ? 1 :
                                            0);
                        pg->point_params[0] = pg->point_params[7] = 1;
                        pg->point_params[3] = 4;
                        const unsigned starts[] = { NV_IGRAPH_XF_XFCTX_CMAT0,
                                                    NV_IGRAPH_XF_XFCTX_MMAT0,
                                                    NV_IGRAPH_XF_XFCTX_IMMAT0 };
                        const float one = 1;
                        for (unsigned m = 0; m < 3; m++)
                            for (unsigned k = 0; k < 4; k++)
                                memcpy(&pg->vsh_constants[starts[m] + k][k],
                                       &one, 4);
                        NSError *error = nil;
                        NV2AMetalPGRAPHVertexState *raster =
                            [[NV2AMetalPGRAPHVertexState alloc]
                                initWithState:pg
                                        error:&error];
                        require(raster != nil, error);
                        pg->surface_binding_dim.width =
                            pg->surface_binding_dim.height = 0;
                        memset(&pg->surface_shape, 0,
                               sizeof(pg->surface_shape));
                        memcpy(before, pg, sizeof(*pg));
                        NV2AMetalPGRAPHVertexState *raw =
                            [[NV2AMetalPGRAPHVertexState alloc]
                                initRawXFWithState:pg
                                             error:&error];
                        require(raw != nil, error);
                        NSData *wire = raw.snapshotData;
                        NV2AMetalEpochResult *whole =
                            [executor executeState:raw
                                   attributeBuffer:gpu
                                             first:1
                                             count:4
                                             error:&error];
                        require(whole != nil, error);
                        NV2AMetalEpochResult *reference =
                            [executor executeState:raster
                                   attributeBuffer:gpu
                                             first:1
                                             count:4
                                             error:&error];
                        require(reference != nil, error);
                        require([commands beginWithError:&error] != nil, error);
                        NV2AMetalEpochEncoding *compact = [executor encodeRasterState:raster
                            attributeBuffer:gpu first:1 count:4 commands:commands error:&error];
                        require(compact != nil, error);
                        finish(commands);
                        NV2AMetalEpochResult *small =
                            [compact resolveWithError:&error];
                        require(small != nil, error);
                        assert(!small.registers && small.vertexCount == 4 &&
                               [small.constants isEqual:reference.constants] &&
                               [small.written isEqual:reference.written] &&
                               !memcmp(small.vertices.contents,
                                       reference.vertices.contents,
                                       4 * sizeof(NV2AMetalVertex)));
                        assert(!memcmp(whole.registers.contents,
                                       reference.registers.contents,
                                       4 * sizeof(NV2AMetalProgramOutput)));
                        const NV2AMetalProgramOutput *registers =
                            whole.registers.contents;
                        for (unsigned v = 0; v < 4; v++) {
                            assert(registers[v].registers[0][0] == v + 2 &&
                                   registers[v].registers[0][1] == 2);
                            assert(registers[v].registers[6][0] ==
                                   (point ? 10 : 6));
                        }
                        const uint8_t *zero = whole.vertices.contents;
                        for (NSUInteger i = 0; i < 4 * sizeof(NV2AMetalVertex);
                             i++)
                            assert(!zero[i]);
                        NV2AMetalEpochResult *prefix =
                            [executor executeState:raw
                                   attributeBuffer:gpu
                                             first:1
                                             count:2
                                             error:&error];
                        require(prefix != nil, error);
                        NV2AMetalPGRAPHVertexState *updated =
                            [raw stateByApplyingConstants:prefix.constants
                                                  written:prefix.written
                                                    error:&error];
                        require(updated != nil, error);
                        assert([updated.snapshotData isEqualToData:wire]);
                        NV2AMetalPGRAPHVertexState *restored =
                            [[NV2AMetalPGRAPHVertexState alloc]
                                initWithSnapshot:updated.snapshotData
                                           error:&error];
                        require(restored != nil, error);
                        assert(restored.rasterDiscard && !restored.programmed);
                        NV2AMetalEpochResult *suffix =
                            [executor executeState:restored
                                   attributeBuffer:gpu
                                             first:3
                                             count:2
                                             error:&error];
                        require(suffix != nil, error);
                        assert(!memcmp(prefix.registers.contents,
                                       whole.registers.contents,
                                       2 * sizeof(NV2AMetalProgramOutput)));
                        assert(!memcmp(suffix.registers.contents, registers + 2,
                                       2 * sizeof(NV2AMetalProgramOutput)));
                        assert(
                            [whole.constants isEqualToData:prefix.constants] &&
                            [whole.constants isEqualToData:suffix.constants]);
                        const uint32_t *written = whole.written.bytes;
                        for (unsigned row = 0; row < 192; row++)
                            assert(!written[row]);
                        NV2AMetalEpochResult *empty =
                            [executor executeState:restored
                                   attributeBuffer:gpu
                                             first:6
                                             count:0
                                             error:&error];
                        require(empty != nil, error);
                        assert(!empty.vertexCount && !empty.registers &&
                               !empty.vertices);
                        assert(
                            [empty.constants isEqualToData:whole.constants] &&
                            [empty.written isEqualToData:whole.written]);
                        assert([raw.snapshotData isEqualToData:wire] &&
                               !memcmp(pg, before, sizeof(*pg)));
                        cases++;
                    }
    id<MTLBuffer> readback =
        [commands.device newBufferWithLength:sizeof(inputs)
                                     options:MTLResourceStorageModeShared];
    assert(readback);
    copyBuffer(commands, gpu, readback);
    assert(!memcmp(readback.contents, inputs, sizeof(inputs)));
    assert(cases == 64);
    puts(
        "Raw fixed capture->Metal4 epoch:64 lighting/normal/two-side/point/fog "
        "cases,320 calls including64 empty;768 vertices,512 raw; private "
        "suffix/prefix/snapshot/restore matches regular raw output; finite "
        "position/point oracles and zero raster vertices PASS");
    puts("Compact fixed lighting:64 exact raster/constant/dirty comparisons,256 vertices, "
         "lighting/normal/two-side/point/fog PASS");
    free(before);
    free(pg);
}

#include "test-metal-shared-fetch-xf.h"
#include "test-metal-compact-xf-benchmark.h"
#include "test-metal-compute-uniform-arena.h"
#include "test-metal-validated-program.h"
#include "test-metal-fixed-specialized-epoch.h"
#include "test-metal-readonly-fault-summary.h"
#include "test-metal-nonwriting-epoch.h"

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        NV2AMetalEpochExecutor *executor =
            [[NV2AMetalEpochExecutor alloc] initWithDevice:commands.device
                                                     error:&error];
        require(executor != nil, error);
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--nonwriting-epoch")))
            nonwriting_epoch_tests(commands, executor);
        if (argc == 2 && !strcmp(argv[1], "--nonwriting-epoch"))
            return 0;
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--readonly-fault-summary")))
            readonly_fault_summary_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--readonly-fault-summary"))
            return 0;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--specialized-fixed")))
            fixed_specialized_epoch_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--specialized-fixed"))
            return 0;
        validated_program_tests(commands);
        if (argc == 2 && !strcmp(argv[1], "--validated-program"))
            return 0;
        compute_uniform_arena_tests(commands.device);
        if (argc == 2 && !strcmp(argv[1], "--uniform-arena"))
            return 0;
        compact_xf_benchmark(commands, executor);
        shared_fetch_xf_tests(commands.device);
        if (argc == 2 && !strcmp(argv[1], "--shared-recording"))
            return 0;
        raw_fixed_epoch_tests(commands, executor);
        NV2AMetalVertexFixed *reference =
            [[NV2AMetalVertexFixed alloc] initWithDevice:commands.device
                                                   error:&error];
        require(reference != nil, error);
        NV2AMetalProgramInput inputs[8] = { 0 };
        for (unsigned v = 0; v < 8; v++)
            for (unsigned a = 0; a < 16; a++)
                for (unsigned k = 0; k < 4; k++)
                    inputs[v].attributes[a][k] =
                        (float)(1 + v * 64 + a * 4 + k);
        id<MTLBuffer> staging =
            [commands.device newBufferWithBytes:inputs
                                         length:sizeof(inputs)
                                        options:MTLResourceStorageModeShared];
        id<MTLBuffer> gpu =
            [commands.device newBufferWithLength:sizeof(inputs)
                                         options:MTLResourceStorageModePrivate];
        assert(staging && gpu);
        copyBuffer(commands, staging, gpu);
        unsigned spans = 0, vertices = 0, fixedCases = 0, programCases = 0;
        NV2AMetalPGRAPHVertexState *last = nil;
        for (unsigned version = 1; version <= 5; version++)
            for (unsigned programmed = 0; programmed < 2; programmed++)
                for (unsigned policy = 0; policy < (version == 5 ? 4u : 1u);
                     policy++) {
                    NSData *snapshot = wire(version, programmed, policy);
                    NV2AMetalPGRAPHVertexState *state =
                        [[NV2AMetalPGRAPHVertexState alloc]
                            initWithSnapshot:snapshot
                                       error:&error];
                    require(state != nil, error);
                    last = state;
                    for (unsigned first = 0; first <= 8; first++)
                        for (unsigned count = 0; count <= 8 - first; count++)
                            @autoreleasepool {
                                error = nil;
                                NV2AMetalEpochResult *r =
                                    [executor executeState:state
                                           attributeBuffer:gpu
                                                     first:first
                                                     count:count
                                                     error:&error];
                                require(r != nil, error);
                                assert(r.vertexCount == count);
                                NV2AMetalProgramUniforms u =
                                    state.programUniforms;
                                float constants[192][4];
                                memcpy(constants, u.constants,
                                       sizeof(constants));
                                if (programmed) {
                                    const NV2AMetalProgramOutput *raw =
                                        r.registers.contents;
                                    for (unsigned v = 0; v < count; v++) {
                                        assert(
                                            !raw[v].fault &&
                                            !memcmp(
                                                raw[v].registers[0],
                                                inputs[first + v].attributes[0],
                                                16));
                                        const float *expected =
                                            state.writeEnable ?
                                                inputs[first + v]
                                                    .attributes[1] :
                                                u.constants[191];
                                        assert(!memcmp(raw[v].registers[9],
                                                       expected, 16));
                                    }
                                    if (state.writeEnable && count)
                                        memcpy(constants[191],
                                               inputs[first + count - 1]
                                                   .attributes[1],
                                               16);
                                    programCases++;
                                } else {
                                    NV2AMetalFixedUniforms fixed =
                                        state.fixedUniforms;
                                    id<MTLBuffer> selected = [commands.device
                                        newBufferWithBytes:count ?
                                                               inputs + first :
                                                               inputs
                                                    length:
                                                        count ?
                                                            count *
                                                                sizeof(
                                                                    inputs[0]) :
                                                            sizeof(inputs[0])
                                                   options:
                                                       MTLResourceStorageModeShared];
                                    assert(selected);
                                    require([commands beginWithError:&error] !=
                                                nil,
                                            error);
                                    NV2AMetalFixedResult *expected =
                                        [reference encodeAttributes:selected
                                                              count:count
                                                           uniforms:&fixed
                                                           commands:commands
                                                              error:&error];
                                    require(expected != nil, error);
                                    finish(commands);
                                    if (count) {
                                        assert(!memcmp(
                                            r.registers.contents,
                                            expected.registers.contents,
                                            count *
                                                sizeof(
                                                    NV2AMetalProgramOutput)));
                                        assert(!memcmp(
                                            r.vertices.contents,
                                            expected.vertices.contents,
                                            count * sizeof(NV2AMetalVertex)));
                                    }
                                    fixedCases++;
                                }
                                assert(!memcmp(r.constants.bytes, constants,
                                               sizeof(constants)));
                                const uint32_t *dirty = r.written.bytes;
                                for (unsigned row = 0; row < 192; row++)
                                    assert(dirty[row] ==
                                           (unsigned)(programmed &&
                                                      state.writeEnable &&
                                                      count && row == 191));
                                if (!count)
                                    assert(!r.registers && !r.vertices);
                                assert([state.snapshotData
                                    isEqualToData:snapshot]);
                                spans++;
                                vertices += count;
                            }
                }
        const NSUInteger bad[][2] = {
            { 9, 0 }, { 8, 1 }, { NSUIntegerMax, 0 }, { 0, NSUIntegerMax }
        };
        for (unsigned i = 0; i < 4; i++) {
            error = nil;
            assert(![executor executeState:last
                           attributeBuffer:gpu
                                     first:bad[i][0]
                                     count:bad[i][1]
                                     error:&error] &&
                   error);
        }
        id<MTLBuffer> readback =
            [commands.device newBufferWithLength:sizeof(inputs)
                                         options:MTLResourceStorageModeShared];
        assert(readback);
        copyBuffer(commands, gpu, readback);
        assert(!memcmp(readback.contents, inputs, sizeof(inputs)));
        assert(spans == 720 && vertices == 1920 && fixedCases == 360 &&
               programCases == 360);
        puts("Native captured epochs: 720 suffix spans/1920 vertices, 360 "
             "fixed GPU comparisons/360 programmable exact MOV cases, captures "
             "v1-v5/all policies, private inputs unchanged, four invalid "
             "ranges PASS; no PGRAPH commit");
    }
    return 0;
}
