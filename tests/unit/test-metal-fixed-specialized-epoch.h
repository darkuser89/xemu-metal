/* Native Fixed Function Constants through legacy capture/epoch adapters.
 * SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef TEST_METAL_FIXED_SPECIALIZED_EPOCH_H
#define TEST_METAL_FIXED_SPECIALIZED_EPOCH_H
@interface FixedEpochGeneral : NV2AMetalVertexFixed
@end
@implementation FixedEpochGeneral
- (id<MTLComputePipelineState>)pipelineForUniforms:
                                   (const NV2AMetalFixedUniforms *)u
                                           compact:(BOOL)compact
{
    (void)u;
    return [self valueForKey:compact ? @"rasterPipeline" : @"pipeline"];
}
@end
static void fixed_specialized_epoch_tests(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalEpochExecutor *native =
        [[NV2AMetalEpochExecutor alloc] initWithDevice:commands.device
                                                 error:&error];
    require(native != nil, error);
    NV2AMetalEpochExecutor *reference =
        [[NV2AMetalEpochExecutor alloc] initWithDevice:commands.device
                                                 error:&error];
    require(reference != nil, error);
    NV2AMetalVertexFixed *general =
        [[FixedEpochGeneral alloc] initWithDevice:commands.device error:&error];
    require(general != nil, error);
    [reference setValue:general forKey:@"fixed"];
    NV2AMetalVertexFixed *fixed = [native valueForKey:@"fixed"];
    NV2AMetalProgramInput values[5] = { 0 };
    for (unsigned i = 0; i < 5; i++) {
        values[i].attributes[0][0] = i + 1;
        values[i].attributes[0][1] = values[i].attributes[0][2] = 2;
        values[i].attributes[0][3] = 1;
        values[i].attributes[2][2] = 1;
        for (unsigned a = 3; a < 13; a++)
            values[i].attributes[a][3] = 1;
    }
    id<MTLBuffer> shared =
        [commands.device newBufferWithBytes:values
                                     length:sizeof(values)
                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> source =
        [commands.device newBufferWithLength:sizeof(values)
                                     options:MTLResourceStorageModePrivate];
    assert(shared && source);
    copyBuffer(commands, shared, source);
    unsigned pairs = 0;
    for (unsigned version = 1; version <= 6; version++) {
        NSData *saved;
        if (version == 6) {
            PGRAPHState *pg = calloc(1, sizeof(*pg));
            assert(pg);
            pg->surface_scale_factor = 1;
            const unsigned starts[] = { NV_IGRAPH_XF_XFCTX_CMAT0,
                                        NV_IGRAPH_XF_XFCTX_MMAT0,
                                        NV_IGRAPH_XF_XFCTX_IMMAT0 };
            float one = 1;
            for (unsigned m = 0; m < 3; m++)
                for (unsigned k = 0; k < 4; k++)
                    memcpy(&pg->vsh_constants[starts[m] + k][k], &one, 4);
            NV2AMetalPGRAPHVertexState *raw =
                [[NV2AMetalPGRAPHVertexState alloc] initRawXFWithState:pg
                                                                 error:&error];
            require(raw != nil, error);
            saved = raw.snapshotData;
            free(pg);
            assert(ldl_be_p((const uint8_t *)saved.bytes + 4) == 6);
        } else
            saved = wire(version, 0, 0);
        NV2AMetalPGRAPHVertexState *state =
            [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:saved
                                                           error:&error];
        require(state != nil, error);
        require([commands beginWithError:&error] != nil, error);
        for (unsigned warm = 0; warm < 4; warm++)
            require([native encodeState:state
                        attributeBuffer:source
                                  first:1
                                  count:3
                               commands:commands
                                  error:&error] != nil,
                    error);
        finish(commands);
        dispatch_sync(
            (dispatch_queue_t)[fixed valueForKey:@"specializationQueue"], ^{
            });
        id variant = [fixed valueForKey:@"variant"];
        assert([[variant valueForKey:@"pipelines"] count] == 2 &&
               ![variant valueForKey:@"error"]);
        for (unsigned compact = 0; compact < (version == 6 ? 1 : 2);
             compact++) {
            uint64_t before = [[fixed valueForKey:@"specializedDispatches"]
                unsignedLongLongValue];
            require([commands beginWithError:&error] != nil, error);
            NV2AMetalEpochEncoding *a = compact ?
                                            [native encodeRasterState:state
                                                      attributeBuffer:source
                                                                first:1
                                                                count:3
                                                             commands:commands
                                                                error:&error] :
                                            [native encodeState:state
                                                attributeBuffer:source
                                                          first:1
                                                          count:3
                                                       commands:commands
                                                          error:&error];
            require(a != nil, error);
            NV2AMetalEpochEncoding *b =
                compact ? [reference encodeRasterState:state
                                       attributeBuffer:source
                                                 first:1
                                                 count:3
                                              commands:commands
                                                 error:&error] :
                          [reference encodeState:state
                                 attributeBuffer:source
                                           first:1
                                           count:3
                                        commands:commands
                                           error:&error];
            require(b != nil, error);
            finish(commands);
            NV2AMetalEpochResult *ar = [a resolveWithError:&error],
                                 *br = [b resolveWithError:&error];
            require(ar != nil && br != nil, error);
            assert([[fixed valueForKey:@"specializedDispatches"]
                       unsignedLongLongValue] == before + 1 &&
                   ar.vertexCount == 3 && br.vertexCount == 3 &&
                   [ar.constants isEqual:br.constants] &&
                   [ar.written isEqual:br.written] &&
                   !memcmp(ar.vertices.contents, br.vertices.contents,
                           3 * sizeof(NV2AMetalVertex)));
            if (!compact)
                assert(!memcmp(ar.registers.contents, br.registers.contents,
                               3 * sizeof(NV2AMetalProgramOutput)));
            else
                assert(!ar.registers && !br.registers);
            pairs++;
        }
    }
    assert(pairs == 11);
    puts("Specialized Fixed epochs:v1-v5 full/compact plus v6 unbound raw,11 "
         "exact private-input suffix pairs;native "
         "dispatch,raw/raster/constant/dirty results and restore validation "
         "PASS");
}
#endif
