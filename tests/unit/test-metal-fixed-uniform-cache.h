/* Recording-local fixed parameters versus the original unconditional upload.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_FIXED_UNIFORM_CACHE_H
#define TEST_METAL_FIXED_UNIFORM_CACHE_H
#import <objc/runtime.h>

@interface NV2AMetalVertexFixed (FixedUniformCacheTest)
- (id<MTLComputePipelineState>)pipelineForUniforms:
                                   (const NV2AMetalFixedUniforms *)u
                                           compact:(BOOL)compact
                                             error:(NSError **)error;
- (MTLGPUAddress)addressForParameters:
                     (const NV2AMetalFixedParameters *)parameters
                             commands:(NV2AMetalCommands *)commands
                                error:(NSError **)error;
@end
@interface FixedUniformCommands : NV2AMetalCommands
@property(nonatomic) NSUInteger parameterCalls, parameterBytes;
@property(nonatomic) BOOL rejectUpload;
@property(nonatomic) NSMutableArray<NSData *> *payloads;
@end
@implementation FixedUniformCommands
- (id<MTLBuffer>)uploadBytes:(const void *)bytes
                      length:(NSUInteger)length
                      offset:(NSUInteger *)offset
                       error:(NSError **)error
{
    BOOL parameter = length == sizeof(NV2AMetalFixedParameters);
    if (parameter) {
        _parameterCalls++;
        if (_rejectUpload) {
            _rejectUpload = NO;
            if (error)
                *error = [NSError errorWithDomain:@"test.fixed-uniform.upload"
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

@interface FixedUniformProbe : NV2AMetalVertexFixed
@property(nonatomic) NSUInteger pipelineCalls;
@property(nonatomic) BOOL rejectPipeline;
@end
@implementation FixedUniformProbe
- (id<MTLComputePipelineState>)pipelineForUniforms:
                                   (const NV2AMetalFixedUniforms *)u
                                           compact:(BOOL)compact
                                             error:(NSError **)error
{
    _pipelineCalls++;
    if (_rejectPipeline) {
        _rejectPipeline = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.fixed-uniform.pipeline"
                                         code:1
                                     userInfo:nil];
        return nil;
    }
    return [super pipelineForUniforms:u compact:compact error:error];
}
@end
@interface FixedUniformReference : FixedUniformProbe
@end
@implementation FixedUniformReference
- (MTLGPUAddress)addressForParameters:
                     (const NV2AMetalFixedParameters *)parameters
                             commands:(NV2AMetalCommands *)commands
                                error:(NSError **)error
{
    /* Original full upload, independent of the new cache implementation. */
    NSUInteger offset;
    id<MTLBuffer> buffer = [commands uploadBytes:parameters
                                          length:sizeof(*parameters)
                                          offset:&offset
                                           error:error];
    return buffer ? buffer.gpuAddress + offset : 0;
}
@end

static NV2AMetalCommands *fuc_fail_owner;
static BOOL fuc_reject_encoder;
static unsigned fuc_encoder_failures;
static id<MTL4ComputeCommandEncoder> (*fuc_encoder_original)(id, SEL);
static id<MTL4ComputeCommandEncoder> fuc_encoder(id object, SEL selector)
{
    if (object == fuc_fail_owner.commandBuffer && fuc_reject_encoder) {
        fuc_reject_encoder = NO;
        fuc_encoder_failures++;
        return nil;
    }
    return fuc_encoder_original(object, selector);
}
static FixedUniformCommands *fuc_commands(id<MTLDevice> device)
{
    NSError *error = nil;
    FixedUniformCommands *commands =
        [[FixedUniformCommands alloc] initWithDevice:device error:&error];
    require(commands != nil, error);
    return commands;
}
static FixedUniformProbe *fuc_fixed(id<MTLDevice> device, BOOL reference)
{
    NSError *error = nil;
    FixedUniformProbe *fixed = [(reference ? FixedUniformReference.class :
                                             FixedUniformProbe.class) alloc];
    fixed = [fixed initWithDevice:device error:&error];
    require(fixed != nil, error);
    return fixed;
}
static id<MTLBuffer> fuc_attributes(id<MTLDevice> device, unsigned salt)
{
    NV2AMetalProgramInput values[12];
    for (unsigned i = 0; i < 12; i++) {
        values[i] = input();
        values[i].attributes[0][0] = .25f + i * .25f + salt * .125f;
        values[i].attributes[0][1] = .5f + i * .125f;
        values[i].attributes[0][2] = .75f + i * .0625f;
        for (unsigned a = 3; a <= 12; a++)
            for (unsigned lane = 0; lane < 4; lane++)
                values[i].attributes[a][lane] += (i + salt) * .03125f;
    }
    id<MTLBuffer> buffer =
        [device newBufferWithBytes:values
                            length:sizeof(values)
                           options:MTLResourceStorageModeShared];
    assert(buffer);
    return buffer;
}
static NV2AMetalFixedResult *
fuc_encode(FixedUniformProbe *fixed, FixedUniformCommands *commands,
           id<MTLBuffer> attributes, const NV2AMetalFixedUniforms *u,
           NSUInteger first, NSUInteger count, BOOL rasterize, BOOL compact)
{
    NSError *error = nil;
    NSData *before = [NSData dataWithBytes:u length:sizeof(*u)];
    NV2AMetalFixedResult *result = [fixed encodeAttributes:attributes
                                                     first:first
                                                     count:count
                                                  uniforms:u
                                                 rasterize:rasterize
                                          compactRegisters:compact
                                                  commands:commands
                                                     error:&error];
    require(result != nil, error);
    assert(result.vertexCount == count && !memcmp(before.bytes, u, sizeof(*u)));
    assert(result.vertices.length == count * sizeof(NV2AMetalVertex));
    assert(compact ? result.registers == nil :
                     result.registers.length ==
                         count * sizeof(NV2AMetalProgramOutput));
    return result;
}
static void fuc_append(NSMutableData *data, NV2AMetalFixedResult *result)
{
    NSUInteger count = result.vertexCount;
    [data appendBytes:&count length:sizeof(count)];
    [data appendBytes:result.vertices.contents length:result.vertices.length];
    if (result.registers)
        [data appendBytes:result.registers.contents
                   length:result.registers.length];
}
static void fuc_exact(NSData *actual, NSData *expected, const char *scope,
                      unsigned profile)
{
    if (![actual isEqualToData:expected]) {
        fprintf(stderr,
                "Fixed uniform %s exact GPU output mismatch profile%u\n", scope,
                profile);
        abort();
    }
}

static NSData *fuc_sequence(FixedUniformProbe *fixed, id<MTLDevice> device,
                            unsigned profile, BOOL reference)
{
    FixedUniformCommands *commands = fuc_commands(device);
    id<MTLBuffer> sources[] = { fuc_attributes(device, 0),
                                fuc_attributes(device, 3) };
    NSData *sourceBytes[] = { [NSData dataWithBytes:sources[0].contents
                                             length:sources[0].length],
                              [NSData dataWithBytes:sources[1].contents
                                             length:sources[1].length] };
    unsigned steps = profile == 0 ? 8 : profile == 4 ? 5 : 6;
    const unsigned misses[] = { 1, 3, 2, 2, 2, 6 };
    fixed.pipelineCalls = 0;
    NSMutableArray<NV2AMetalFixedResult *> *results = [NSMutableArray new];
    NSMutableArray<NSNumber *> *firsts = [NSMutableArray new],
                               *sourceIDs = [NSMutableArray new];
    begin(commands);
    for (unsigned step = 0; step < steps; step++) {
        NV2AMetalFixedUniforms u = uniforms();
        u.common.vertex_count =
            UINT32_C(0xfeedface); /* The actual count replaces this. */
        unsigned count = 3;
        BOOL rasterize = YES, compact = NO;
        if (profile == 1)
            count = (unsigned[]){ 1, 3, 7 }[step % 3];
        if (profile == 2) {
            rasterize = !(step & 1);
            compact = step & 1;
        }
        if (profile == 3)
            u.common.point_size += step & 1;
        if (profile == 4) {
            /* Unused by this unlit fixture, but part of the exact key. */
            uint32_t nan = (step == 2 || step == 3) ? UINT32_C(0x7fc54321) :
                                                      UINT32_C(0x7fc12345);
            memcpy(&u.specular_params[0], &nan, 4);
        }
        if (profile == 5)
            u.common.point_size += step < 5 ? step : 0;
        unsigned first = step % 3, source = step & 1;
        NV2AMetalFixedResult *r =
            fuc_encode(fixed, commands, sources[source], &u, first, count,
                       rasterize, compact);
        for (NV2AMetalFixedResult *old in results)
            assert(r.vertices != old.vertices &&
                   (!r.registers || r.registers != old.registers));
        [results addObject:r];
        [firsts addObject:@(first)];
        [sourceIDs addObject:@(source)];
    }
    finish(commands);
    NSMutableData *output = [NSMutableData new];
    for (unsigned i = 0; i < results.count; i++) {
        NV2AMetalFixedResult *r = results[i];
        fuc_append(output, r);
        if (r.registers) {
            const NV2AMetalProgramOutput *raw = r.registers.contents;
            const NV2AMetalProgramInput *source =
                sources[sourceIDs[i].unsignedIntValue].contents;
            for (NSUInteger v = 0; v < r.vertexCount; v++) {
                assert(!raw[v].fault);
                check_float(raw[v].registers[0][0],
                            source[firsts[i].unsignedIntegerValue + v]
                                .attributes[0][0]);
            }
        }
    }
    for (unsigned i = 0; i < 2; i++)
        assert(!memcmp(sourceBytes[i].bytes, sources[i].contents,
                       sources[i].length));
    NSUInteger expected = reference ? steps : misses[profile];
    assert(commands.parameterCalls == expected &&
           commands.payloads.count == expected &&
           commands.parameterBytes ==
               expected * sizeof(NV2AMetalFixedParameters) &&
           fixed.pipelineCalls == steps);
    if (profile == 4) {
        BOOL sawA = NO, sawB = NO;
        for (NSData *payload in commands.payloads) {
            const NV2AMetalFixedParameters *p = payload.bytes;
            uint32_t nan;
            memcpy(&nan, &p->uniforms.specular_params[0], 4);
            assert(p->uniforms.common.vertex_count == 3 && p->rasterize);
            sawA |= nan == UINT32_C(0x7fc12345);
            sawB |= nan == UINT32_C(0x7fc54321);
        }
        assert(sawA && sawB);
    }
    return output;
}

static NSData *fuc_queue_scope(FixedUniformProbe *fixed, id<MTLDevice> device)
{
    FixedUniformCommands *a = fuc_commands(device), *b = fuc_commands(device);
    id<MTLBuffer> attributes = fuc_attributes(device, 2);
    NV2AMetalFixedUniforms u = uniforms();
    begin(a);
    begin(b);
    assert(a.recordingSerial == 1 && b.recordingSerial == 1);
    fixed.pipelineCalls = 0;
    NV2AMetalFixedResult *r0 =
        fuc_encode(fixed, a, attributes, &u, 0, 3, YES, NO);
    NV2AMetalFixedResult *r1 =
        fuc_encode(fixed, b, attributes, &u, 3, 3, YES, NO);
    NV2AMetalFixedResult *r2 =
        fuc_encode(fixed, a, attributes, &u, 6, 3, YES, NO);
    finish(a);
    finish(b);
    NSMutableData *data = [NSMutableData new];
    fuc_append(data, r0);
    fuc_append(data, r1);
    fuc_append(data, r2);
    assert(a.parameterCalls == 2 && b.parameterCalls == 1 &&
           fixed.pipelineCalls == 3 &&
           a.parameterBytes == 2 * sizeof(NV2AMetalFixedParameters) &&
           b.parameterBytes == sizeof(NV2AMetalFixedParameters));
    assert(
        memcmp(r0.vertices.contents, r1.vertices.contents, r0.vertices.length));
    return data;
}

static NSData *fuc_recording_scope(FixedUniformProbe *fixed,
                                   id<MTLDevice> device, BOOL reference)
{
    NSError *error = nil;
    FixedUniformCommands *commands = fuc_commands(device);
    id<MTLBuffer> attributes = fuc_attributes(device, 1);
    NV2AMetalFixedUniforms u = uniforms();
    NSMutableArray<NV2AMetalFixedResult *> *keep = [NSMutableArray new];
    begin(commands);
    [keep addObject:fuc_encode(fixed, commands, attributes, &u, 1, 3, YES, NO)];
    [keep addObject:fuc_encode(fixed, commands, attributes, &u, 2, 3, YES, NO)];
    uint64_t serial = commands.recordingSerial;
    require([commands sealWithError:&error], error);
    NSUInteger calls = commands.parameterCalls, probes = fixed.pipelineCalls;
    assert(![fixed encodeAttributes:attributes
                              first:0
                              count:3
                           uniforms:&u
                          rasterize:YES
                   compactRegisters:NO
                           commands:commands
                              error:&error] &&
           error && commands.parameterCalls == calls &&
           fixed.pipelineCalls == probes);
    error = nil;
    begin(commands);
    assert(commands.recordingSerial > serial);
    u.common.point_size += 1;
    (void)fuc_encode(fixed, commands, attributes, &u, 3, 3, YES, NO);
    serial = commands.recordingSerial;
    [commands cancelUnsealed];
    begin(commands);
    assert(commands.recordingSerial > serial);
    [keep addObject:fuc_encode(fixed, commands, attributes, &u, 4, 3, YES, NO)];
    /* If a cancelled section's address were reused without advancing this
     * recording's upload cursor, the next upload would overwrite live A with
     * valid but observably different B. The proper cache has already uploaded
     * A into this new recording and appends B after it. */
    NV2AMetalFixedParameters other = { .uniforms = u, .rasterize = YES };
    other.uniforms.common.vertex_count = 3;
    other.uniforms.common.point_size += 10;
    uint8_t bytes[sizeof(other) + 1];
    memcpy(bytes, &other, sizeof(other));
    bytes[sizeof(other)] = 0;
    NSUInteger ignored;
    require([commands uploadBytes:bytes
                           length:sizeof(bytes)
                           offset:&ignored
                            error:&error] != nil,
            error);
    finish(commands);
    NSUInteger slots = [[commands valueForKey:@"slots"] count];
    assert(slots && slots <= 8);
    for (NSUInteger i = 0; i < slots; i++) {
        begin(commands);
        assert(commands.recordingSerial > serial);
        serial = commands.recordingSerial;
        [keep addObject:fuc_encode(fixed, commands, attributes, &u, i % 3, 3,
                                   YES, NO)];
        [keep addObject:fuc_encode(fixed, commands, attributes, &u, i % 3 + 1,
                                   3, YES, NO)];
        finish(commands);
    }
    NSMutableData *data = [NSMutableData new];
    for (NV2AMetalFixedResult *result in keep)
        fuc_append(data, result);
    NSUInteger expected = reference ? 4 + 2 * slots : 3 + slots;
    assert(commands.parameterCalls == expected &&
           commands.parameterBytes ==
               expected * sizeof(NV2AMetalFixedParameters));
    return data;
}

static NSData *fuc_failures(FixedUniformProbe *fixed, id<MTLDevice> device,
                            BOOL reference)
{
    NSError *error = nil;
    FixedUniformCommands *commands = fuc_commands(device);
    id<MTLBuffer> attributes = fuc_attributes(device, 0);
    NV2AMetalFixedUniforms u = uniforms();
    fixed.pipelineCalls = 0;
    begin(commands);
    NV2AMetalFixedResult *a =
        fuc_encode(fixed, commands, attributes, &u, 0, 3, YES, NO);
    fixed.rejectPipeline = YES;
    assert(![fixed encodeAttributes:attributes
                              first:0
                              count:3
                           uniforms:&u
                          rasterize:YES
                   compactRegisters:NO
                           commands:commands
                              error:&error] &&
           [error.domain isEqualToString:@"test.fixed-uniform.pipeline"] &&
           commands.parameterCalls == 1 && fixed.pipelineCalls == 2);
    error = nil;
    NV2AMetalFixedUniforms invalid = u;
    invalid.skinning = 7;
    assert(![fixed encodeAttributes:attributes
                              first:0
                              count:3
                           uniforms:&invalid
                          rasterize:YES
                   compactRegisters:NO
                           commands:commands
                              error:&error] &&
           error && fixed.pipelineCalls == 2 && commands.parameterCalls == 1);
    error = nil;
    assert(![fixed encodeAttributes:attributes
                              first:11
                              count:3
                           uniforms:&u
                          rasterize:YES
                   compactRegisters:NO
                           commands:commands
                              error:&error] &&
           error && fixed.pipelineCalls == 2 && commands.parameterCalls == 1);
    error = nil;
    NV2AMetalFixedResult *empty = [fixed encodeAttributes:attributes
                                                    first:12
                                                    count:0
                                                 uniforms:&u
                                                rasterize:YES
                                         compactRegisters:NO
                                                 commands:commands
                                                    error:&error];
    require(empty != nil, error);
    assert(!empty.vertexCount && !empty.vertices && !empty.registers &&
           fixed.pipelineCalls == 2 && commands.parameterCalls == 1);
    u.common.point_size += 1;
    commands.rejectUpload = YES;
    assert(![fixed encodeAttributes:attributes
                              first:0
                              count:3
                           uniforms:&u
                          rasterize:YES
                   compactRegisters:NO
                           commands:commands
                              error:&error] &&
           [error.domain isEqualToString:@"test.fixed-uniform.upload"] &&
           commands.parameterCalls == 2 &&
           commands.parameterBytes == sizeof(NV2AMetalFixedParameters));
    error = nil;
    NV2AMetalFixedResult *b =
        fuc_encode(fixed, commands, attributes, &u, 1, 3, YES, NO);
    u.common.point_size += 1;
    Method encoder =
        class_getInstanceMethod(object_getClass(commands.commandBuffer),
                                @selector(computeCommandEncoder));
    assert(encoder);
    fuc_encoder_original =
        (void *)method_setImplementation(encoder, (IMP)fuc_encoder);
    fuc_fail_owner = commands;
    fuc_reject_encoder = YES;
    fuc_encoder_failures = 0;
    @try {
        assert(![fixed encodeAttributes:attributes
                                  first:0
                                  count:3
                               uniforms:&u
                              rasterize:YES
                       compactRegisters:NO
                               commands:commands
                                  error:&error] &&
               error && !fuc_reject_encoder && fuc_encoder_failures == 1 &&
               commands.parameterCalls == 4);
    } @finally {
        method_setImplementation(encoder, (IMP)fuc_encoder_original);
        fuc_fail_owner = nil;
        fuc_reject_encoder = NO;
    }
    error = nil;
    NV2AMetalFixedResult *c =
        fuc_encode(fixed, commands, attributes, &u, 2, 3, YES, NO);
    assert(a.vertices != b.vertices && a.vertices != c.vertices &&
           b.vertices != c.vertices);
    finish(commands);
    NSMutableData *data = [NSMutableData new];
    fuc_append(data, a);
    fuc_append(data, b);
    fuc_append(data, c);
    assert(fixed.pipelineCalls == 6 &&
           commands.parameterCalls == (reference ? 5u : 4u) &&
           commands.parameterBytes ==
               (reference ? 4u : 3u) * sizeof(NV2AMetalFixedParameters));
    return data;
}

static void fuc_owner_release(FixedUniformProbe *fixed, id<MTLDevice> device)
{
    __weak FixedUniformCommands *dead = nil;
    @autoreleasepool {
        FixedUniformCommands *commands = fuc_commands(device);
        dead = commands;
        id<MTLBuffer> attributes = fuc_attributes(device, 0);
        NV2AMetalFixedUniforms u = uniforms();
        begin(commands);
        (void)fuc_encode(fixed, commands, attributes, &u, 0, 3, YES, NO);
        finish(commands);
    }
    assert(!dead); /* Cache must not retain the command owner or its arenas. */
    FixedUniformCommands *fresh = fuc_commands(device);
    NV2AMetalFixedUniforms u = uniforms();
    id<MTLBuffer> attributes = fuc_attributes(device, 1);
    begin(fresh);
    (void)fuc_encode(fixed, fresh, attributes, &u, 0, 3, YES, NO);
    finish(fresh);
    assert(fresh.parameterCalls == 1 &&
           fresh.parameterBytes == sizeof(NV2AMetalFixedParameters));
}

static void fixed_uniform_cache_tests(id<MTLDevice> device)
{
    FixedUniformProbe *fixed[] = { fuc_fixed(device, NO),
                                   fuc_fixed(device, YES) };
    unsigned pairs = 0;
    for (unsigned profile = 0; profile < 6; profile++) {
        NSData *output[2];
        for (unsigned order = 0; order < 2; order++) {
            unsigned reference = (order + profile) & 1;
            output[reference] =
                fuc_sequence(fixed[reference], device, profile, reference);
        }
        fuc_exact(output[0], output[1], "sequence", profile);
        pairs++;
    }
    fuc_exact(fuc_queue_scope(fixed[0], device),
              fuc_queue_scope(fixed[1], device), "two queues", 6);
    pairs++;
    fuc_exact(fuc_recording_scope(fixed[0], device, NO),
              fuc_recording_scope(fixed[1], device, YES), "recordings", 7);
    pairs++;
    fuc_exact(fuc_failures(fixed[0], device, NO),
              fuc_failures(fixed[1], device, YES), "failures", 8);
    pairs++;
    fuc_owner_release(fixed[0], device);
    assert(pairs == 9);
    puts("Fixed uniform cache:9 exact full GPU vertex/register pairs,8 "
         "repeated ranges "
         "upload 5352 instead of 42816 bytes;count/rasterize/compact/state/NaN "
         "bits,"
         "4-slot eviction,changing sources,two queues with "
         "serial1,seal/cancel/slot reuse,"
         "owner release,pipeline/upload/late encoder failures and retry PASS");
}

#endif
