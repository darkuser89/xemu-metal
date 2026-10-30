/* Queued compute uniforms: dedicated buffers versus command-slot arena.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_COMPUTE_UNIFORM_ARENA_H
#define TEST_METAL_COMPUTE_UNIFORM_ARENA_H
#import "hw/xbox/nv2a/pgraph/metal/geometry.h"
#import "hw/xbox/nv2a/pgraph/metal/vertex-program.h"

@interface UniformArenaCommands : NV2AMetalCommands
@property(nonatomic) BOOL dedicated;
@property(nonatomic) unsigned uploadDepth, nonzeroOffsets;
@property(nonatomic) NSUInteger copiedBytes;
@property(nonatomic) NSMutableArray *uploads;
@property(nonatomic) NSHashTable *buffers;
@end
@implementation UniformArenaCommands
- (id<MTLBuffer>)uploadBytes:(const void *)bytes
                      length:(NSUInteger)length
                      offset:(NSUInteger *)offset
                       error:(NSError **)error
{
    _uploadDepth++;
    id<MTLBuffer> buffer;
    if (_dedicated) {
        buffer = [self.device newBufferWithBytes:bytes
                                          length:length
                                         options:MTLResourceStorageModeShared];
        if (buffer && ![self addResource:buffer error:error])
            buffer = nil;
        *offset = 0;
    } else {
        buffer = [super uploadBytes:bytes
                             length:length
                             offset:offset
                              error:error];
    }
    _uploadDepth--;
    /* A page rollover recursively calls uploadBytes. Count only the caller's
     * request; retain a copy to verify all queued uniforms remain immutable. */
    if (buffer && !_uploadDepth) {
        if (*offset)
            _nonzeroOffsets++;
        _copiedBytes += length;
        [_buffers addObject:buffer];
        [_uploads addObject:@[
            buffer, @(*offset), [NSData dataWithBytes:bytes length:length]
        ]];
        assert(*offset % 256 == 0);
    }
    return buffer;
}
@end

static void uniform_equal_buffer(id<MTLBuffer> a, id<MTLBuffer> b)
{
    assert((a == nil) == (b == nil));
    if (a) {
        assert(a.length == b.length);
        assert(!memcmp(a.contents, b.contents, a.length));
    }
}

static void compute_uniform_arena_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    UniformArenaCommands *arena =
        [[UniformArenaCommands alloc] initWithDevice:device error:&error];
    UniformArenaCommands *dedicated =
        [[UniformArenaCommands alloc] initWithDevice:device error:&error];
    dedicated.dedicated = YES;
    NV2AMetalVertexFetch *fetch =
        [[NV2AMetalVertexFetch alloc] initWithDevice:device error:&error];
    NV2AMetalVertexFixed *fixed =
        [[NV2AMetalVertexFixed alloc] initWithDevice:device error:&error];
    NV2AMetalVertexProgram *legacy =
        [[NV2AMetalVertexProgram alloc] initWithDevice:device error:&error];
    NV2AMetalWritableProgram *program =
        [[NV2AMetalWritableProgram alloc] initWithDevice:device error:&error];
    NV2AMetalGeometry *geometry =
        [[NV2AMetalGeometry alloc] initWithDevice:device error:&error];
    require(arena && dedicated && fetch && fixed && legacy && program &&
                geometry,
            error);
    NV2AMetalPGRAPHVertexState *fixedState =
        [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:wire(4, 0, 0)
                                                       error:&error];
    NV2AMetalPGRAPHVertexState *programState =
        [[NV2AMetalPGRAPHVertexState alloc] initWithSnapshot:wire(4, 1, 0)
                                                       error:&error];
    require(fixedState && programState, error);
    Token tokens[3] = { token(1, 0, 96), token(1, 0, 96), token(1, 0, 97) };
    source(&tokens[0], 0, 2, 0, 0xe4);
    destination(&tokens[0], 0x170, 15, 0, 0, 0, 0);
    source(&tokens[1], 0, 3, 0, 0xe4);
    destination(&tokens[1], 0x173, 15, 0, 0, 0, 0);
    tokens[1].word[3] |= 1;
    source(&tokens[2], 0, 2, 0, 0xe4);
    destination(&tokens[2], 97, 15, 0, 0, 0, 0);
    tokens[2].word[3] |= 1;
    float positions[3][4] = { { 8, 8, 2, 1 },
                              { 24, 8, 3, 1 },
                              { 8, 24, 4, 1 } };
    id<MTLBuffer> positionsBuffer =
        [device newBufferWithBytes:positions
                            length:sizeof(positions)
                           options:MTLResourceStorageModeShared];
    assert(positionsBuffer);
    NSHashTable *arenaPages = [NSHashTable
        hashTableWithOptions:NSPointerFunctionsStrongMemory |
                             NSPointerFunctionsObjectPointerPersonality];
    NSUInteger pairs = 0, arenaBuffers = 0, dedicatedBuffers = 0,
               copiedBytes = 0, nonzero = 0;
    /* Five completed recordings exercise all three command slots and reuse.
     * No submission occurs between the 24 differing states in a recording. */
    for (unsigned round = 0; round < 5; round++) {
        @autoreleasepool {
            for (UniformArenaCommands *commands in @[ arena, dedicated ]) {
                commands.uploads = [NSMutableArray new];
                commands.buffers = [NSHashTable
                    hashTableWithOptions:
                        NSPointerFunctionsStrongMemory |
                        NSPointerFunctionsObjectPointerPersonality];
                commands.copiedBytes = commands.nonzeroOffsets = 0;
                require([commands beginWithError:&error] != nil, error);
                /* Leave only 256 bytes in the first arena page. The first
                 * Fetch rolls to page two; later XF/geometry bindings have
                 * nonzero offsets. Poison makes a missing offset visible. */
                NSMutableData *pad = [NSMutableData dataWithLength:65536 - 256];
                memset(pad.mutableBytes, 0xa5, pad.length);
                NSUInteger offset = 0;
                require([commands uploadBytes:pad.bytes
                                       length:pad.length
                                       offset:&offset
                                        error:&error] != nil,
                        error);
            }
            NSMutableArray *encoded[2] = { [NSMutableArray new],
                                           [NSMutableArray new] };
            for (unsigned i = 0; i < 24; i++) {
                NV2AMetalAttributeSource sources[16] = { 0 };
                sources[0].buffer = positionsBuffer;
                sources[0].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
                sources[0].count = 4;
                sources[0].stride = sizeof(positions[0]);
                for (unsigned a = 1; a < 16; a++)
                    for (unsigned k = 0; k < 4; k++)
                        sources[a].inline_value[k] =
                            (i + round + a + k) * .015625f;
                NV2AMetalFixedUniforms fu = fixedState.fixedUniforms;
                NV2AMetalProgramUniforms pu = programState.programUniforms;
                fu.common.point_size = pu.point_size = 1 + i + round;
                pu.constants[96][0] = .015625f * (1 + i + round);
                pu.constants[96][1] = .25f;
                pu.constants[96][2] = .5f;
                pu.constants[96][3] = 1;
                BOOL writable = i % 3 == 2;
                BOOL compact = !writable && (i & 1);
                Token writableTokens[3];
                memcpy(writableTokens, tokens, sizeof(tokens));
                writableTokens[1].word[3] &= ~1u;
                for (unsigned mode = 0; mode < 2; mode++) {
                    UniformArenaCommands *commands = mode ? dedicated : arena;
                    NV2AMetalFetchResult *f = [fetch encodeSources:sources
                                                             count:3
                                                       firstVertex:0
                                                           indices:nil
                                                       indexOffset:0
                                                         indexSize:0
                                                     currentVertex:2
                                                          commands:commands
                                                             error:&error];
                    require(f != nil, error);
                    NV2AMetalFixedResult *ff =
                        [fixed encodeAttributes:f.attributes
                                          first:0
                                          count:3
                                       uniforms:&fu
                                      rasterize:YES
                               compactRegisters:compact
                                       commands:commands
                                          error:&error];
                    NV2AMetalProgramResult *vp =
                        [legacy encodeTokens:tokens[0].word
                                      length:2
                                    uniforms:&pu
                                  attributes:f.attributes
                                       count:3
                                    commands:commands
                                       error:&error];
                    require(ff && vp, error);
                    NV2AMetalWritableEncoding *wp = [program
                            encodeTokens:writable ? writableTokens[0].word :
                                                    tokens[0].word
                                  length:writable ? 3 : 2
                                uniforms:&pu
                         attributeBuffer:f.attributes
                                   first:0
                                   count:3
                                  access:1
                             writeEnable:writable
                               rasterize:YES
                        compactRegisters:compact
                                commands:commands
                                   error:&error];
                    enum NV2AMetalPolygonMode polygon =
                        i % 3 == 0 ? NV2AMetalPolygonLine :
                                     NV2AMetalPolygonFill;
                    NV2AMetalGeometryRasterConfig config = {
                        .front = polygon,
                        .back = polygon,
                        .viewportWidth = 64,
                        .viewportHeight = 64,
                        .lineWidth = 1 + i % 4,
                    };
                    NSArray<NV2AMetalGeometryResult *> *streams = [geometry
                        encodeRasterVertices:vp.vertices
                                       count:3
                                   primitive:i % 2 ? NV2AMetalPrimitivePolygon :
                                                     NV2AMetalPrimitiveTriangles
                                      config:&config
                                      smooth:(i & 2) != 0
                              firstProvoking:(i & 4) != 0
                                zPerspective:(i & 8) != 0
                                    commands:commands
                                       error:&error];
                    require(streams != nil, error);
                    assert(streams.count == 1);
                    NV2AMetalGeometryResult *g = streams[0];
                    require(wp && g, error);
                    [encoded[mode] addObject:@[ f, ff, vp, wp, g ]];
                }
            }
            assert(arena.uploads.count == 121 &&
                   dedicated.uploads.count == 121);
            assert(arena.copiedBytes == dedicated.copiedBytes);
            assert(arena.buffers.count > 2 && arena.buffers.count < 16);
            assert(dedicated.buffers.count == 121 && arena.nonzeroOffsets > 90);
            for (UniformArenaCommands *commands in @[ arena, dedicated ]) {
                for (NSArray *u in commands.uploads) {
                    id<MTLBuffer> b = u[0];
                    NSData *expected = u[2];
                    assert(!memcmp((char *)b.contents +
                                       [u[1] unsignedIntegerValue],
                                   expected.bytes, expected.length));
                }
                finish(commands);
            }
            for (unsigned i = 0; i < 24; i++) {
                NSArray *a = encoded[0][i], *b = encoded[1][i];
                NV2AMetalFetchResult *fa = a[0], *fb = b[0];
                uniform_equal_buffer(fa.attributes, fb.attributes);
                uniform_equal_buffer(fa.faults, fb.faults);
                assert(fa.hasCurrent && fa.vertexCount == 3);
                for (unsigned v = 0; v < 4; v++)
                    assert(!((uint32_t *)fa.faults.contents)[v]);
                NV2AMetalFixedResult *ffa = a[1], *ffb = b[1];
                uniform_equal_buffer(ffa.registers, ffb.registers);
                uniform_equal_buffer(ffa.vertices, ffb.vertices);
                NV2AMetalProgramResult *vpa = a[2], *vpb = b[2];
                uniform_equal_buffer(vpa.registers, vpb.registers);
                uniform_equal_buffer(vpa.vertices, vpb.vertices);
                const NV2AMetalProgramOutput *raw = vpa.registers.contents;
                for (unsigned v = 0; v < 3; v++) {
                    assert(!raw[v].fault);
                    assert(raw[v].registers[3][0] ==
                           .015625f * (1 + i + round));
                }
                NV2AMetalWritableResult *wa = [a[3] resolveWithError:&error];
                NV2AMetalWritableResult *wb = [b[3] resolveWithError:&error];
                require(wa && wb, error);
                uniform_equal_buffer(wa.registers, wb.registers);
                uniform_equal_buffer(wa.vertices, wb.vertices);
                assert([wa.constants isEqual:wb.constants] &&
                       [wa.written isEqual:wb.written]);
                NV2AMetalGeometryResult *ga = a[4], *gb = b[4];
                assert(ga.vertexCount == gb.vertexCount &&
                       ga.primitiveType == gb.primitiveType);
                uniform_equal_buffer(ga.vertices, gb.vertices);
                pairs++;
            }
            for (id buffer in arena.buffers)
                [arenaPages addObject:buffer];
            arenaBuffers += arena.buffers.count;
            dedicatedBuffers += dedicated.buffers.count;
            copiedBytes += arena.copiedBytes;
            nonzero += arena.nonzeroOffsets;
            arena.uploads = dedicated.uploads = nil;
            arena.buffers = dedicated.buffers = nil;
        }
    }
    assert(arenaPages.count < arenaBuffers);
    printf("Compute uniform arena: %lu exact five-stage pairs; %lu arena "
           "buffer uses versus %lu dedicated; %lu nonzero offsets; %lu logical "
           "bytes copied per mode (includes rollover padding); five "
           "recordings, no app\n",
           (unsigned long)pairs, (unsigned long)arenaBuffers,
           (unsigned long)dedicatedBuffers, (unsigned long)nonzero,
           (unsigned long)copiedBytes);
    printf(
        "Compute uniform arena: %lu distinct arena pages across three slots; "
        "600 production uniform requests, five rollover-padding requests\n",
        (unsigned long)arenaPages.count);
}
#endif
