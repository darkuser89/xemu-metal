/* Recording-local parameter reuse versus the original unconditional upload.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_WRITABLE_UNIFORM_CACHE_H
#define TEST_METAL_WRITABLE_UNIFORM_CACHE_H
#import <objc/runtime.h>
#include "hw/xbox/nv2a/pgraph/metal/vertex-context-types.h"

@interface NV2AMetalWritableProgram (WritableUniformCacheTest)
- (MTLGPUAddress)addressForParameters:
                     (const NV2AMetalWritableParameters *)parameters
                             commands:(NV2AMetalCommands *)commands
                                error:(NSError **)error;
- (id<MTLComputePipelineState>)interpreterPipelineWithWrites:(BOOL)write
                                                     compact:(BOOL)compact
                                                     discard:(BOOL)discard
                                                     chained:(BOOL)chained
                                                 independent:(BOOL)independent
                                                       error:(NSError **)error;
@end
@interface WritableUniformCommands : NV2AMetalCommands
@property(nonatomic) NSUInteger parameterCalls, parameterBytes;
@property(nonatomic) BOOL rejectUpload;
@property(nonatomic) NSMutableArray<NSData *> *payloads;
@end
@implementation WritableUniformCommands
- (id<MTLBuffer>)uploadBytes:(const void *)bytes
                      length:(NSUInteger)length
                      offset:(NSUInteger *)offset
                       error:(NSError **)error
{
    BOOL parameter = length == sizeof(NV2AMetalWritableParameters);
    if (parameter) {
        _parameterCalls++;
        if (_rejectUpload) {
            _rejectUpload = NO;
            if (error)
                *error =
                    [NSError errorWithDomain:@"test.writable-uniform.upload"
                                        code:1
                                    userInfo:nil];
            return nil;
        }
    }
    id<MTLBuffer> buffer = [super uploadBytes:bytes
                                       length:length
                                       offset:offset
                                        error:error];
    if (parameter && buffer) {
        _parameterBytes += length;
        if (!_payloads)
            _payloads = [NSMutableArray new];
        [_payloads addObject:[NSData dataWithBytes:bytes length:length]];
    }
    return buffer;
}
@end
@interface WritableUniformProbe : NV2AMetalWritableProgram
@property(nonatomic) NSUInteger pipelineCalls;
@property(nonatomic) BOOL rejectPipeline;
@end
@implementation WritableUniformProbe
- (id<MTLComputePipelineState>)interpreterPipelineWithWrites:(BOOL)write
                                                     compact:(BOOL)compact
                                                     discard:(BOOL)discard
                                                     chained:(BOOL)chained
                                                 independent:(BOOL)independent
                                                       error:(NSError **)error
{
    _pipelineCalls++;
    if (_rejectPipeline) {
        _rejectPipeline = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.writable-uniform.pipeline"
                                         code:1
                                     userInfo:nil];
        return nil;
    }
    return [super interpreterPipelineWithWrites:write
                                        compact:compact
                                        discard:discard
                                        chained:chained
                                    independent:independent
                                          error:error];
}
@end
@interface WritableUniformReference : WritableUniformProbe
@end
@implementation WritableUniformReference
- (MTLGPUAddress)addressForParameters:
                     (const NV2AMetalWritableParameters *)parameters
                             commands:(NV2AMetalCommands *)commands
                                error:(NSError **)error
{
    /* The former upload at the same call site; no cache state is consulted. */
    NSUInteger offset;
    id<MTLBuffer> buffer = [commands uploadBytes:parameters
                                          length:sizeof(*parameters)
                                          offset:&offset
                                           error:error];
    return buffer ? buffer.gpuAddress + offset : 0;
}
@end

static WritableUniformCommands *wuc_commands(id<MTLDevice> device)
{
    NSError *error = nil;
    WritableUniformCommands *commands =
        [[WritableUniformCommands alloc] initWithDevice:device error:&error];
    require(commands != nil, error);
    return commands;
}
static WritableUniformProbe *wuc_engine(id<MTLDevice> device, BOOL reference)
{
    NSError *error = nil;
    WritableUniformProbe *program =
        [(reference ? WritableUniformReference.class :
                      WritableUniformProbe.class) alloc];
    program = [program initWithDevice:device error:&error];
    require(program != nil, error);
    return program;
}
static NV2AMetalValidatedProgram *wuc_program(void)
{
    Token tokens[7];
    writable_tokens(tokens, 120, 3, 15);
    NSError *error = nil;
    NV2AMetalValidatedProgram *program =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:tokens[0].word
                                                   length:7
                                                    error:&error];
    require(program != nil, error);
    return program;
}
static id<MTLBuffer> wuc_attributes(id<MTLDevice> device, unsigned salt)
{
    NV2AMetalProgramInput values[12];
    for (unsigned i = 0; i < 12; i++) {
        writable_input(values + i, i);
        for (unsigned a = 0; a < 16; a++)
            for (unsigned k = 0; k < 4; k++)
                values[i].attributes[a][k] += i * .125f + salt * .25f;
    }
    id<MTLBuffer> buffer =
        [device newBufferWithBytes:values
                            length:sizeof(values)
                           options:MTLResourceStorageModeShared];
    assert(buffer);
    return buffer;
}
static void wuc_begin(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
}
static void wuc_finish(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
}
static NV2AMetalWritableEncoding *
wuc_encode(WritableUniformProbe *engine, NV2AMetalValidatedProgram *program,
           NV2AMetalCommands *commands, id<MTLBuffer> attributes,
           const NV2AMetalProgramUniforms *u, NSUInteger first,
           NSUInteger count, unsigned access, BOOL write, BOOL rasterize,
           BOOL compact)
{
    NSError *error = nil;
    NV2AMetalWritableEncoding *encoded = [engine encodeProgram:program
                                                      uniforms:u
                                               attributeBuffer:attributes
                                                         first:first
                                                         count:count
                                                        access:access
                                                   writeEnable:write
                                                     rasterize:rasterize
                                              compactRegisters:compact
                                                      commands:commands
                                                         error:&error];
    require(encoded != nil, error);
    return encoded;
}
static NV2AMetalWritableResult *wuc_resolve(NV2AMetalWritableEncoding *encoded)
{
    NSError *error = nil;
    NV2AMetalWritableResult *result = [encoded resolveWithError:&error];
    require(result != nil, error);
    return result;
}
static void wuc_append(NSMutableData *data, NV2AMetalWritableResult *result)
{
    uint64_t count = result.vertexCount;
    uint8_t flags = !!result.registers | (!!result.vertices << 1);
    [data appendBytes:&count length:sizeof(count)];
    [data appendBytes:&flags length:sizeof(flags)];
    assert(result.constants.length == 3072 && result.written.length == 768);
    [data appendData:result.constants];
    [data appendData:result.written];
    if (result.registers)
        [data appendBytes:result.registers.contents
                   length:count * sizeof(NV2AMetalProgramOutput)];
    if (result.vertices)
        [data appendBytes:result.vertices.contents
                   length:count * sizeof(NV2AMetalVertex)];
}
static void wuc_exact(NSData *actual, NSData *expected, const char *label)
{
    if (![actual isEqual:expected]) {
        fprintf(stderr, "Writable uniform cache %s: GPU/context bytes differ\n",
                label);
        abort();
    }
}
static NSData *wuc_metrics(NSMutableData *data, uint64_t a, uint64_t b,
                           uint64_t c, uint64_t expectedA, uint64_t expectedB,
                           uint64_t expectedC)
{
    uint64_t metrics[] = { a, b, c, expectedA, expectedB, expectedC };
    [data appendBytes:metrics length:sizeof(metrics)];
    return data;
}
static void wuc_counted_exact(NSData *a, NSData *b, const char *label)
{
    const NSUInteger tail = 6 * sizeof(uint64_t);
    assert(a.length >= tail && b.length >= tail);
    wuc_exact([a subdataWithRange:NSMakeRange(0, a.length - tail)],
              [b subdataWithRange:NSMakeRange(0, b.length - tail)], label);
    for (NSData *data in @[ a, b ]) {
        uint64_t metrics[6];
        [data getBytes:metrics range:NSMakeRange(data.length - tail, tail)];
        for (unsigned i = 0; i < 3; i++)
            assert(metrics[i] == metrics[i + 3]);
    }
}
static NSData *wuc_sequence(id<MTLDevice> device, unsigned profile,
                            BOOL reference)
{
    WritableUniformCommands *commands = wuc_commands(device);
    WritableUniformProbe *engine = wuc_engine(device, reference);
    NV2AMetalValidatedProgram *program = wuc_program();
    id<MTLBuffer> sources[] = { wuc_attributes(device, 0),
                                wuc_attributes(device, 1) };
    NSData *sourceBytes[] = { [NSData dataWithBytes:sources[0].contents
                                             length:sources[0].length],
                              [NSData dataWithBytes:sources[1].contents
                                             length:sources[1].length] };
    NSMutableArray<NV2AMetalWritableEncoding *> *encodings =
        [NSMutableArray new];
    NSMutableArray<NSNumber *> *firsts = [NSMutableArray new],
                               *sourceIDs = [NSMutableArray new];
    wuc_begin(commands);
    const NSUInteger counts[] = { 0, 1, 3, 1, 0, 3, 2, 2 };
    for (unsigned i = 0; i < 8; i++) {
        NV2AMetalProgramUniforms u = uniforms();
        NSUInteger count = profile == 1 ? counts[i] : 3;
        BOOL write = profile == 2 ? (i >> 1) & 1 : profile == 3;
        BOOL rasterize = profile == 2 ? i & 1 : YES;
        BOOL compact = profile == 3 ? i & 1 : NO;
        unsigned access = profile == 3 ? (i >> 1) & 1 : 1;
        if (profile == 4) {
            uint32_t bits = i & 1 ? 0x7fc54321u : 0x7fc12345u;
            memcpy(&u.constants[191][0], &bits, 4);
            bits = i & 2 ? 0x80000000u : 0;
            memcpy(&u.constants[190][0], &bits, 4);
        }
        if (profile == 5)
            u.point_size += i < 5 ? i : 0;
        /* These two caller fields are normalized before the upload key. */
        u.vertex_count = 1000 + i;
        u.program_length = 100 + i;
        unsigned first = i % 3, sourceID = i & 1;
        NV2AMetalWritableEncoding *encoded =
            wuc_encode(engine, program, commands, sources[sourceID], &u, first,
                       count, access, write, rasterize, compact);
        [encodings addObject:encoded];
        [firsts addObject:@(first)];
        [sourceIDs addObject:@(sourceID)];
        memset(&u, 0xa5, sizeof(u)); // Caller bytes must never be borrowed.
    }
    wuc_finish(commands);
    NSMutableData *output = [NSMutableData new];
    NSMutableArray<NV2AMetalWritableResult *> *resolved = [NSMutableArray new];
    for (unsigned i = 0; i < encodings.count; i++) {
        NV2AMetalWritableResult *r = wuc_resolve(encodings[i]);
        for (NV2AMetalWritableResult *old in resolved)
            assert((!r.vertices || r.vertices != old.vertices) &&
                   (!r.registers || r.registers != old.registers));
        [resolved addObject:r];
        wuc_append(output, r);
        if (r.registers) {
            const NV2AMetalProgramOutput *raw = r.registers.contents;
            const NV2AMetalProgramInput *source =
                sources[sourceIDs[i].unsignedIntValue].contents;
            for (NSUInteger v = 0; v < r.vertexCount; v++) {
                assert(!raw[v].fault);
                assert(!memcmp(
                    raw[v].registers[0],
                    source[firsts[i].unsignedIntegerValue + v].attributes[0],
                    16));
            }
        }
    }
    for (unsigned i = 0; i < 2; i++)
        assert(!memcmp(sourceBytes[i].bytes, sources[i].contents,
                       sources[i].length));
    /* Check GPU bytes before performance metadata in the caller. */
    NSUInteger expected[] = { 1, 4, 4, 2, 4, 6 };
    uint64_t metrics[] = { commands.parameterCalls, commands.parameterBytes,
                           engine.pipelineCalls, expected[profile] };
    [output appendBytes:metrics length:sizeof(metrics)];
    return output;
}
static void wuc_sequence_equal(NSData *a, NSData *b)
{
    const NSUInteger tail = 4 * sizeof(uint64_t);
    assert(a.length >= tail && b.length >= tail);
    wuc_exact([a subdataWithRange:NSMakeRange(0, a.length - tail)],
              [b subdataWithRange:NSMakeRange(0, b.length - tail)], "sequence");
    uint64_t ca[4], cb[4];
    [a getBytes:ca range:NSMakeRange(a.length - tail, tail)];
    [b getBytes:cb range:NSMakeRange(b.length - tail, tail)];
    assert(ca[0] == ca[3] && cb[0] == 8 && ca[2] == 8 && cb[2] == 8 &&
           ca[1] == ca[0] * sizeof(NV2AMetalWritableParameters) &&
           cb[1] == cb[0] * sizeof(NV2AMetalWritableParameters));
}
static NSData *wuc_queues(id<MTLDevice> device, BOOL reference)
{
    WritableUniformProbe *engine = wuc_engine(device, reference);
    WritableUniformCommands *a = wuc_commands(device),
                            *b = wuc_commands(device);
    NV2AMetalValidatedProgram *program = wuc_program();
    NV2AMetalProgramUniforms u = uniforms();
    id<MTLBuffer> attributes = wuc_attributes(device, 1);
    wuc_begin(a);
    wuc_begin(b);
    assert(a.recordingSerial == 1 && b.recordingSerial == 1);
    NV2AMetalWritableEncoding *r[] = {
        wuc_encode(engine, program, a, attributes, &u, 0, 3, 1, NO, YES, NO),
        wuc_encode(engine, program, b, attributes, &u, 3, 3, 1, NO, YES, NO),
        wuc_encode(engine, program, a, attributes, &u, 6, 3, 1, NO, YES, NO)
    };
    wuc_finish(a);
    wuc_finish(b);
    NSMutableData *data = [NSMutableData new];
    for (unsigned i = 0; i < 3; i++)
        wuc_append(data, wuc_resolve(r[i]));
    return wuc_metrics(data, a.parameterCalls, b.parameterCalls,
                       engine.pipelineCalls, 2, 1, 3);
}
static NSData *wuc_recordings(id<MTLDevice> device, BOOL reference)
{
    WritableUniformProbe *engine = wuc_engine(device, reference);
    WritableUniformCommands *commands = wuc_commands(device);
    NV2AMetalValidatedProgram *program = wuc_program();
    NV2AMetalProgramUniforms u = uniforms();
    id<MTLBuffer> attributes = wuc_attributes(device, 1);
    NSMutableArray<NV2AMetalWritableEncoding *> *keep = [NSMutableArray new];
    NSError *error = nil;
    wuc_begin(commands);
    [keep addObject:wuc_encode(engine, program, commands, attributes, &u, 0, 3,
                               1, NO, YES, NO)];
    [keep addObject:wuc_encode(engine, program, commands, attributes, &u, 1, 3,
                               1, NO, YES, NO)];
    uint64_t serial = commands.recordingSerial;
    require([commands sealWithError:&error], error);
    assert(![engine encodeProgram:program
                         uniforms:&u
                  attributeBuffer:attributes
                            first:0
                            count:3
                           access:1
                      writeEnable:NO
                        rasterize:YES
                 compactRegisters:NO
                         commands:commands
                            error:&error] &&
           error && engine.pipelineCalls == 2 &&
           commands.parameterCalls == (reference ? 2u : 1u));
    error = nil;
    wuc_begin(commands);
    assert(commands.recordingSerial > serial);
    u.point_size += 1; // Cancelled B differs from the sealed prefix's A.
    (void)wuc_encode(engine, program, commands, attributes, &u, 2, 3, 1, NO,
                     YES, NO);
    serial = commands.recordingSerial;
    [commands cancelUnsealed];
    wuc_begin(commands);
    assert(commands.recordingSerial > serial);
    [keep addObject:wuc_encode(engine, program, commands, attributes, &u, 3, 3,
                               1, NO, YES, NO)];
    /* Missing generation reset reuses B without advancing the rewound arena;
     * this differently sized upload then overwrites live GPU parameter B. */
    NV2AMetalWritableParameters other = { .common = u,
                                          .full_access = 1,
                                          .rasterize = YES };
    other.common.vertex_count = 3;
    other.common.program_length = 7;
    other.common.point_size += 10;
    uint8_t overwrite[sizeof(other) + 1];
    memcpy(overwrite, &other, sizeof(other));
    overwrite[sizeof(other)] = 0;
    NSUInteger ignored;
    require([commands uploadBytes:overwrite
                           length:sizeof(overwrite)
                           offset:&ignored
                            error:&error] != nil,
            error);
    wuc_finish(commands);
    NSUInteger slots = [[commands valueForKey:@"slots"] count];
    assert(slots && slots <= 8);
    for (NSUInteger i = 0; i < slots; i++) {
        wuc_begin(commands);
        assert(commands.recordingSerial > serial);
        serial = commands.recordingSerial;
        [keep addObject:wuc_encode(engine, program, commands, attributes, &u,
                                   i % 3, 3, 1, NO, YES, NO)];
        [keep addObject:wuc_encode(engine, program, commands, attributes, &u,
                                   i % 3 + 1, 3, 1, NO, YES, NO)];
        wuc_finish(commands);
    }
    NSMutableData *data = [NSMutableData new];
    for (NV2AMetalWritableEncoding *encoding in keep)
        wuc_append(data, wuc_resolve(encoding));
    NSUInteger expected = reference ? 4 + 2 * slots : 3 + slots;
    return wuc_metrics(data, commands.parameterCalls, commands.parameterBytes,
                       engine.pipelineCalls, expected,
                       expected * sizeof(NV2AMetalWritableParameters),
                       4 + 2 * slots);
}

/* wuc_failures strongly owns commands throughout this synchronous hook. */
static _Thread_local __unsafe_unretained NV2AMetalCommands *wuc_fail_owner;
static _Thread_local BOOL wuc_reject_encoder;
static _Thread_local unsigned wuc_encoder_failures;
static id<MTL4ComputeCommandEncoder> (*wuc_encoder_original)(id, SEL);
static id<MTL4ComputeCommandEncoder> wuc_encoder(id object, SEL selector)
{
    if (object == wuc_fail_owner.commandBuffer && wuc_reject_encoder) {
        wuc_reject_encoder = NO;
        wuc_encoder_failures++;
        return nil;
    }
    return wuc_encoder_original(object, selector);
}
static NSData *wuc_failures(id<MTLDevice> device, BOOL reference)
{
    WritableUniformProbe *engine = wuc_engine(device, reference);
    WritableUniformCommands *commands = wuc_commands(device);
    NV2AMetalValidatedProgram *program = wuc_program();
    NV2AMetalProgramUniforms u = uniforms();
    id<MTLBuffer> attributes = wuc_attributes(device, 0);
    NSError *error = nil;
    wuc_begin(commands);
    NV2AMetalWritableEncoding *a = wuc_encode(
        engine, program, commands, attributes, &u, 0, 3, 1, NO, YES, NO);
    engine.rejectPipeline = YES;
    assert(![engine encodeProgram:program
                         uniforms:&u
                  attributeBuffer:attributes
                            first:0
                            count:3
                           access:1
                      writeEnable:NO
                        rasterize:YES
                 compactRegisters:NO
                         commands:commands
                            error:&error] &&
           [error.domain isEqual:@"test.writable-uniform.pipeline"] &&
           commands.parameterCalls == 1 && engine.pipelineCalls == 2);
    error = nil;
    NV2AMetalProgramUniforms invalid = u;
    invalid.surface_size[0] = 0;
    assert(![engine encodeProgram:program
                         uniforms:&invalid
                  attributeBuffer:attributes
                            first:0
                            count:3
                           access:1
                      writeEnable:NO
                        rasterize:YES
                 compactRegisters:NO
                         commands:commands
                            error:&error] &&
           error && engine.pipelineCalls == 2 && commands.parameterCalls == 1);
    error = nil;
    assert(![engine encodeProgram:program
                         uniforms:&u
                  attributeBuffer:attributes
                            first:11
                            count:3
                           access:1
                      writeEnable:NO
                        rasterize:YES
                 compactRegisters:NO
                         commands:commands
                            error:&error] &&
           error && engine.pipelineCalls == 2 && commands.parameterCalls == 1);
    error = nil;
    u.point_size += 1;
    commands.rejectUpload = YES;
    assert(![engine encodeProgram:program
                         uniforms:&u
                  attributeBuffer:attributes
                            first:0
                            count:3
                           access:1
                      writeEnable:NO
                        rasterize:YES
                 compactRegisters:NO
                         commands:commands
                            error:&error] &&
           [error.domain isEqual:@"test.writable-uniform.upload"] &&
           commands.parameterCalls == 2 &&
           commands.parameterBytes == sizeof(NV2AMetalWritableParameters));
    error = nil;
    NV2AMetalWritableEncoding *b = wuc_encode(
        engine, program, commands, attributes, &u, 1, 3, 1, NO, YES, NO);
    u.point_size += 1;
    Method method =
        class_getInstanceMethod(object_getClass(commands.commandBuffer),
                                @selector(computeCommandEncoder));
    assert(method);
    wuc_encoder_original = (void *)method_getImplementation(method);
    wuc_fail_owner = commands;
    wuc_reject_encoder = YES;
    wuc_encoder_failures = 0;
    method_setImplementation(method, (IMP)wuc_encoder);
    @try {
        assert(![engine encodeProgram:program
                             uniforms:&u
                      attributeBuffer:attributes
                                first:0
                                count:3
                               access:1
                          writeEnable:NO
                            rasterize:YES
                     compactRegisters:NO
                             commands:commands
                                error:&error] &&
               error && !wuc_reject_encoder && wuc_encoder_failures == 1 &&
               commands.parameterCalls == 4);
    } @finally {
        method_setImplementation(method, (IMP)wuc_encoder_original);
        wuc_fail_owner = nil;
        wuc_reject_encoder = NO;
    }
    error = nil;
    NV2AMetalWritableEncoding *c = wuc_encode(
        engine, program, commands, attributes, &u, 2, 3, 1, NO, YES, NO);
    wuc_finish(commands);
    NSMutableData *data = [NSMutableData new];
    wuc_append(data, wuc_resolve(a));
    wuc_append(data, wuc_resolve(b));
    wuc_append(data, wuc_resolve(c));
    return wuc_metrics(
        data, commands.parameterCalls, commands.parameterBytes,
        engine.pipelineCalls, reference ? 5 : 4,
        (reference ? 4 : 3) * sizeof(NV2AMetalWritableParameters), 6);
}
static NSData *wuc_chain(id<MTLDevice> device, BOOL reference)
{
    WritableUniformProbe *engine = wuc_engine(device, reference);
    WritableUniformCommands *commands = wuc_commands(device);
    NV2AMetalValidatedProgram *program = wuc_program();
    NV2AMetalProgramUniforms u = uniforms();
    id<MTLBuffer> attributes = wuc_attributes(device, 0);
    NSError *error = nil;
    wuc_begin(commands);
    NV2AMetalWritableEncoding *a = [engine encodeSerialProgram:program
                                                      uniforms:&u
                                               attributeBuffer:attributes
                                                         first:0
                                                         count:3
                                                        access:1
                                                     rasterize:YES
                                                      previous:nil
                                                      commands:commands
                                                         error:&error];
    require(a != nil, error);
    NV2AMetalWritableEncoding *b = [engine encodeSerialProgram:program
                                                      uniforms:&u
                                               attributeBuffer:attributes
                                                         first:3
                                                         count:3
                                                        access:1
                                                     rasterize:YES
                                                      previous:a
                                                      commands:commands
                                                         error:&error];
    require(b != nil, error);
    wuc_finish(commands);
    NV2AMetalWritableResult *ra = wuc_resolve(a), *rb = wuc_resolve(b);
    NSMutableData *data = [NSMutableData new];
    wuc_append(data, ra);
    wuc_append(data, rb);
    assert(![ra.constants isEqual:rb.constants]);
    return wuc_metrics(
        data, commands.parameterCalls, commands.parameterBytes,
        engine.pipelineCalls, reference ? 2 : 1,
        (reference ? 2 : 1) * sizeof(NV2AMetalWritableParameters), 2);
}
static void wuc_owner_release(id<MTLDevice> device)
{
    WritableUniformProbe *engine = wuc_engine(device, NO);
    __weak WritableUniformCommands *weak = nil;
    @autoreleasepool {
        WritableUniformCommands *commands = wuc_commands(device);
        weak = commands;
        NV2AMetalProgramUniforms u = uniforms();
        wuc_begin(commands);
        (void)wuc_encode(engine, wuc_program(), commands,
                         wuc_attributes(device, 0), &u, 0, 3, 1, NO, YES, NO);
        wuc_finish(commands);
    }
    assert(!weak);
    WritableUniformCommands *fresh = wuc_commands(device);
    NV2AMetalProgramUniforms u = uniforms();
    wuc_begin(fresh);
    NV2AMetalWritableEncoding *encoded =
        wuc_encode(engine, wuc_program(), fresh, wuc_attributes(device, 1), &u,
                   0, 3, 1, NO, YES, NO);
    wuc_finish(fresh);
    (void)wuc_resolve(encoded);
    assert(fresh.parameterCalls == 1);
}
static void writable_uniform_cache_tests(id<MTLDevice> device)
{
    for (unsigned profile = 0; profile < 6; profile++) {
        NSData *outputs[2];
        for (unsigned order = 0; order < 2; order++) {
            unsigned reference = (order + profile) & 1;
            outputs[reference] = wuc_sequence(device, profile, reference);
        }
        wuc_sequence_equal(outputs[0], outputs[1]);
    }
    wuc_counted_exact(wuc_queues(device, NO), wuc_queues(device, YES),
                      "queues");
    wuc_counted_exact(wuc_recordings(device, NO), wuc_recordings(device, YES),
                      "recordings");
    wuc_counted_exact(wuc_failures(device, NO), wuc_failures(device, YES),
                      "failures");
    wuc_counted_exact(wuc_chain(device, NO), wuc_chain(device, YES),
                      "writer chain");
    wuc_owner_release(device);
    puts("Writable uniform cache:10 exact GPU "
         "register/vertex/constants/write-mask pairs;"
         "8 identical ranges upload3152 instead of25216 "
         "bytes;count/access/write/rasterize/"
         "compact/NaN/signed-zero/4-slot eviction,source offsets,two queues "
         "with serial1,"
         "seal/cancel/arena overwrite/slot reuse,weak "
         "owner,pipeline/upload/late encoder "
         "failure and retry,real previous GPU context PASS");
}
#endif
