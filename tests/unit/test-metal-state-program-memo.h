/* Exact State token-prefix memo versus the original decoder and uploads.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_STATE_PROGRAM_MEMO_H
#define TEST_METAL_STATE_PROGRAM_MEMO_H
#include <sys/mman.h>
#include <unistd.h>
#include "hw/xbox/nv2a/pgraph/metal/vertex-context-types.h"

@interface NV2AMetalStateProgram (StateProgramMemoTest)
- (BOOL)matchesDecodedTokens:(const uint32_t *)tokens length:(NSUInteger)length;
- (BOOL)decodeTokens:(const uint32_t *)tokens
              length:(NSUInteger)length
             decoded:(NV2AMetalProgramInstruction *)decoded
               slots:(NSUInteger *)slots
               error:(NSError **)error;
- (id<MTLBuffer>)newDecodedProgramBuffer:(NSData *)instructions;
- (void)cacheDecodedTokens:(const uint32_t *)tokens
                     slots:(NSUInteger)slots
              instructions:(const NV2AMetalProgramInstruction *)instructions;
@end

typedef struct StateProgramMemoWork {
    __unsafe_unretained NV2AMetalCommands *commands;
    __unsafe_unretained id<MTLBuffer> owned;
    const NV2AMetalStateInput *input;
    const NV2AMetalStateParameters *parameters;
    NSUInteger programBytes, inputCalls, parameterCalls, programCalls;
    unsigned rejectUpload;
    BOOL rejectRegistration;
} StateProgramMemoWork;
static _Thread_local StateProgramMemoWork *spm_work;
static _Thread_local unsigned spm_copyOrdinal, spm_copyFail, spm_copyCalls;
static id<MTLBuffer> (*spm_original_upload)(id, SEL, const void *, NSUInteger,
                                            NSUInteger *, NSError **);
static BOOL (*spm_original_resource)(id, SEL, id<MTLResource>, NSError **);
static id (*spm_original_data)(id, SEL, const void *, NSUInteger);

static id<MTLBuffer> spm_upload(id owner, SEL selector, const void *bytes,
                                NSUInteger length, NSUInteger *offset,
                                NSError **error)
{
    StateProgramMemoWork *w = spm_work;
    unsigned kind = 0;
    if (w && owner == w->commands) {
        if (length == sizeof(NV2AMetalStateInput)) {
            w->inputCalls++;
            assert(!memcmp(bytes, w->input, length));
            kind = 1;
        } else if (length == sizeof(NV2AMetalStateParameters)) {
            w->parameterCalls++;
            assert(!memcmp(bytes, w->parameters, length));
            kind = 2;
        } else {
            assert(length == w->programBytes);
            w->programCalls++;
            kind = 3;
        }
        if (w->rejectUpload == kind) {
            w->rejectUpload = 0;
            if (error)
                *error = [NSError errorWithDomain:@"test.state-memo.upload"
                                             code:kind
                                         userInfo:nil];
            return nil;
        }
    }
    id<MTLBuffer> result =
        spm_original_upload(owner, selector, bytes, length, offset, error);
    if (kind && result) {
        assert(*offset <= result.length && length <= result.length - *offset);
        assert(
            !memcmp((const uint8_t *)result.contents + *offset, bytes, length));
    }
    return result;
}
static BOOL spm_resource(id owner, SEL selector, id<MTLResource> resource,
                         NSError **error)
{
    if (spm_work && owner == spm_work->commands &&
        resource == spm_work->owned && spm_work->rejectRegistration) {
        spm_work->rejectRegistration = NO;
        if (error)
            *error = [NSError errorWithDomain:@"test.state-memo.registration"
                                         code:1
                                     userInfo:nil];
        return NO;
    }
    return spm_original_resource(owner, selector, resource, error);
}
static id spm_data(id owner, SEL selector, const void *bytes, NSUInteger length)
{
    if (spm_copyOrdinal) {
        spm_copyCalls++;
        if (spm_copyCalls == spm_copyFail)
            return nil;
    }
    return spm_original_data(owner, selector, bytes, length);
}

@interface StateProgramMemoProbe : NV2AMetalStateProgram
@property(nonatomic) BOOL reference, rejectMirror;
@property(nonatomic) unsigned rejectCopy;
@property(nonatomic) NSUInteger decodeCalls, mirrorCalls;
@property(nonatomic, weak) id<MTLBuffer> lastMirror;
@end
@implementation StateProgramMemoProbe
- (BOOL)matchesDecodedTokens:(const uint32_t *)tokens length:(NSUInteger)length
{
    return !_reference && [super matchesDecodedTokens:tokens length:length];
}
- (BOOL)decodeTokens:(const uint32_t *)tokens
              length:(NSUInteger)length
             decoded:(NV2AMetalProgramInstruction *)decoded
               slots:(NSUInteger *)slots
               error:(NSError **)error
{
    _decodeCalls++;
    return [super decodeTokens:tokens
                        length:length
                       decoded:decoded
                         slots:slots
                         error:error];
}
- (id<MTLBuffer>)newDecodedProgramBuffer:(NSData *)instructions
{
    _mirrorCalls++;
    if (_rejectMirror) {
        _rejectMirror = NO; // Optional allocation failure is a simulation.
        return nil;
    }
    id<MTLBuffer> result = [super newDecodedProgramBuffer:instructions];
    _lastMirror = result;
    return result;
}
- (void)cacheDecodedTokens:(const uint32_t *)tokens
                     slots:(NSUInteger)slots
              instructions:(const NV2AMetalProgramInstruction *)instructions
{
    if (_reference)
        return;
    assert(!spm_copyOrdinal);
    spm_copyOrdinal = 1;
    spm_copyCalls = 0;
    spm_copyFail = _rejectCopy;
    @try {
        [super cacheDecodedTokens:tokens slots:slots instructions:instructions];
    } @finally {
        spm_copyOrdinal = spm_copyFail = 0;
        _rejectCopy = 0;
    }
}
@end

@interface StateProgramMemoPair : NSObject
@property(nonatomic) StateProgramMemoProbe *original, *candidate;
@property(nonatomic) NSMutableArray<NV2AMetalStateResult *> *results;
@property(nonatomic) NSMutableArray<NSData *> *snapshots;
@end
@implementation StateProgramMemoPair
@end
static StateProgramMemoPair *spm_pair(id<MTLDevice> device)
{
    StateProgramMemoPair *pair = [StateProgramMemoPair new];
    NSError *error = nil;
    pair.original = [[StateProgramMemoProbe alloc] initWithDevice:device
                                                            error:&error];
    pair.candidate = [[StateProgramMemoProbe alloc] initWithDevice:device
                                                             error:&error];
    assert(pair.original && pair.candidate);
    pair.original.reference = YES;
    pair.results = [NSMutableArray new];
    pair.snapshots = [NSMutableArray new];
    return pair;
}
static Token spm_move(unsigned row, unsigned constant, BOOL fromConstant)
{
    Token t = token(1, 0, constant);
    source(&t, 0, fromConstant ? 3 : 2, 0, 0xe4);
    destination(&t, row, 15, 0, 0, 0, 0);
    t.word[3] |= 1;
    return t;
}
static Token spm_nop(BOOL end)
{
    Token t = token(0, 0, 0);
    t.word[3] |= end;
    return t;
}
static NSData *spm_constants(unsigned salt)
{
    uint32_t words[192][4];
    for (unsigned r = 0; r < 192; r++)
        for (unsigned k = 0; k < 4; k++)
            words[r][k] = 0x3f000000 + salt * 0x10000 + r * 4 + k;
    return [NSData dataWithBytes:words length:sizeof(words)];
}
static NSData *spm_launch(unsigned profile)
{
    const uint32_t raw[][4] = {
        { 0x3f800000, 0x40000000, 0x80000000, 0x7fc12345 },
        { 0x40000000, 0x40400000, 1, 0x7fc54321 },
        { 0, 0x80000000, 0x3f000000, 0x3f800000 },
        { 0x7fc12345, 0, 0, 0 },
        { 0x42c00000, 0, 0, 0 }, // ARL96 plus relative c96 reaches row192.
    };
    assert(profile < sizeof(raw) / sizeof(raw[0]));
    return [NSData dataWithBytes:raw[profile] length:sizeof(raw[profile])];
}
static NSData *spm_expected(NSData *constants, unsigned row, const void *value)
{
    NSMutableData *expected = [constants mutableCopy];
    if (value)
        memcpy((uint8_t *)expected.mutableBytes + row * 16, value, 16);
    return expected;
}
static NSData *spm_written(unsigned row, BOOL write)
{
    uint32_t flags[192] = { 0 };
    if (write)
        flags[row] = 1;
    return [NSData dataWithBytes:flags length:sizeof(flags)];
}
static void spm_old_results(StateProgramMemoPair *pair)
{
    assert(pair.results.count * 2 == pair.snapshots.count);
    for (NSUInteger i = 0; i < pair.results.count; i++) {
        assert([pair.results[i].constants isEqualToData:pair.snapshots[2 * i]]);
        assert(
            [pair.results[i].written isEqualToData:pair.snapshots[2 * i + 1]]);
    }
}

/* readSlots is the accessible prefix, never the declared (possibly guarded)
 * length. The expected result is handwritten transport data, not a decoder. */
static void spm_run(StateProgramMemoPair *pair, const uint32_t *tokens,
                    NSUInteger length, NSUInteger readSlots, NSData *constants,
                    NSData *launch, NV2AMetalStateAccess access,
                    NSData *expected, NSData *written, NSUInteger cold,
                    NSUInteger programUploads, BOOL gpu, unsigned rejectUpload,
                    BOOL rejectRegistration)
{
    NSData *oldConstants = [constants copy], *oldLaunch = [launch copy];
    NSData *oldTokens = [NSData dataWithBytes:tokens length:readSlots * 16];
    NV2AMetalStateResult *results[2] = { nil, nil };
    NSError *errors[2] = { nil, nil };
    StateProgramMemoWork works[2] = { 0 };
    NSUInteger calls[2];
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        StateProgramMemoProbe *program =
            candidate ? pair.candidate : pair.original;
        NV2AMetalStateInput input = { 0 };
        NV2AMetalStateParameters parameters = { 0 };
        if (constants.length == sizeof(input.constants))
            memcpy(input.constants, constants.bytes, constants.length);
        if (launch.length == 16)
            memcpy(input.attributes.attributes[0], launch.bytes, 16);
        parameters.common.vertex_count = 1;
        parameters.common.program_length = (unsigned)readSlots;
        parameters.full_access = access == NV2AMetalStateFull;
        StateProgramMemoWork *w = &works[candidate];
        w->commands = [program valueForKey:@"commands"];
        w->owned = program.lastMirror;
        w->input = &input;
        w->parameters = &parameters;
        w->programBytes = readSlots * sizeof(NV2AMetalProgramInstruction);
        w->rejectUpload = rejectUpload;
        w->rejectRegistration = candidate && rejectRegistration;
        NSUInteger before = program.decodeCalls;
        NSError *localError = nil;
        assert(!spm_work);
        spm_work = w;
        @try {
            results[candidate] = [program executeTokens:tokens
                                                 length:length
                                              constants:constants
                                                 launch:launch
                                                 access:access
                                                  error:&localError];
        } @finally {
            spm_work = NULL;
        }
        calls[candidate] = program.decodeCalls - before;
        errors[candidate] = localError;
        assert([constants isEqualToData:oldConstants] &&
               [launch isEqualToData:oldLaunch]);
        assert(!readSlots ||
               !memcmp(tokens, oldTokens.bytes, oldTokens.length));
        assert(!w->commands.commandBuffer);
    }
    if (expected) {
        for (unsigned i = 0; i < 2; i++) {
            if (!results[i] || errors[i]) {
                fprintf(stderr, "State memo side%u: %s\n", i,
                        errors[i].localizedDescription.UTF8String);
                abort();
            }
            assert([results[i].constants isEqualToData:expected] &&
                   [results[i].written isEqualToData:written]);
            [pair.results addObject:results[i]];
            [pair.snapshots addObject:[results[i].constants copy]];
            [pair.snapshots addObject:[results[i].written copy]];
        }
    } else {
        assert(!results[0] && !results[1] && errors[0] && errors[1]);
        assert([errors[0].domain isEqualToString:errors[1].domain] &&
               errors[0].code == errors[1].code &&
               [errors[0].localizedDescription
                   isEqualToString:errors[1].localizedDescription]);
    }
    spm_old_results(pair);
    /* Full GPU snapshots and unchanged caller inputs precede work claims. */
    NSUInteger originalCold =
        constants.length == 3072 && launch.length == 16 &&
        (access == NV2AMetalStateFull || access == NV2AMetalStateUserOnly);
    if (calls[0] != originalCold || calls[1] != cold ||
        works[0].programCalls != (gpu ? 1u : 0u) ||
        works[1].programCalls != programUploads)
        fprintf(
            stderr,
            "State memo length%lu cold%lu/%lu program%lu/%lu expected%lu/%lu\n",
            (unsigned long)length, (unsigned long)calls[0],
            (unsigned long)calls[1], (unsigned long)works[0].programCalls,
            (unsigned long)works[1].programCalls, (unsigned long)cold,
            (unsigned long)programUploads);
    assert(calls[0] == originalCold && calls[1] == cold);
    assert(works[0].programCalls == (gpu ? 1u : 0u) &&
           works[1].programCalls == programUploads);
    for (unsigned i = 0; i < 2; i++) {
        NSUInteger inputCalls = gpu || rejectUpload ? 1 : 0;
        NSUInteger parameterCalls = inputCalls && rejectUpload != 1;
        assert(works[i].inputCalls == inputCalls &&
               works[i].parameterCalls == parameterCalls);
    }
    if (rejectRegistration)
        assert(!works[1].rejectRegistration);
}

static void spm_repeated(id<MTLDevice> device)
{
    StateProgramMemoPair *pair = spm_pair(device);
    NSData *constants = spm_constants(0), *launch = spm_launch(0);
    Token t = spm_move(96, 0, NO);
    NSData *expected = spm_expected(constants, 96, launch.bytes);
    NSData *flags = spm_written(96, YES);
    spm_run(pair, t.word, 1, 1, constants, launch, NV2AMetalStateFull, expected,
            flags, 1, 1, YES, 0, NO);
    Token copy[136];
    memset(copy, 0xff, sizeof(copy));
    copy[0] = t;
    for (unsigned i = 0; i < 3; i++) {
        NSData *freshConstants = spm_constants(i + 1),
               *freshLaunch = spm_launch(i);
        spm_run(pair, copy[0].word, i ? 136 : 1, 1, freshConstants, freshLaunch,
                NV2AMetalStateFull,
                spm_expected(freshConstants, 96, freshLaunch.bytes), flags, 0,
                0, YES, 0, NO);
    }
}
static void spm_guardpages(id<MTLDevice> device)
{
    StateProgramMemoPair *pair = spm_pair(device);
    NSData *constants = spm_constants(0), *launch = spm_launch(0);
    Token longProgram[2] = { spm_nop(NO), spm_move(96, 0, NO) };
    NSData *expected = spm_expected(constants, 96, launch.bytes);
    NSData *flags = spm_written(96, YES);
    spm_run(pair, longProgram[0].word, 2, 2, constants, launch,
            NV2AMetalStateFull, expected, flags, 1, 1, YES, 0, NO);
    long page = sysconf(_SC_PAGESIZE);
    assert(page >= 4096);
    void *mapping = mmap(NULL, 2 * (size_t)page, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(mapping != MAP_FAILED);
    assert(!mprotect((uint8_t *)mapping + page, (size_t)page, PROT_NONE));
    Token *end = (Token *)((uint8_t *)mapping + page - sizeof(Token));
    *end = spm_nop(YES);
    for (unsigned i = 0; i < 2; i++)
        spm_run(pair, end->word, 136, 1, constants, launch, NV2AMetalStateFull,
                constants, spm_written(0, NO), !i, !i, YES, 0, NO);
    spm_run(pair, longProgram[0].word, 2, 2, constants, launch,
            NV2AMetalStateFull, expected, flags, 1, 1, YES, 0, NO);
    /* Invalid declared lengths must be rejected without touching this page. */
    const uint32_t *unreadable = (const uint32_t *)((uint8_t *)mapping + page);
    spm_run(pair, unreadable, 0, 0, constants, launch, NV2AMetalStateFull, nil,
            nil, 1, 0, NO, 0, NO);
    spm_run(pair, unreadable, 137, 0, constants, launch, NV2AMetalStateFull,
            nil, nil, 1, 0, NO, 0, NO);
    assert(!munmap(mapping, 2 * (size_t)page));
}
static void spm_mutation(id<MTLDevice> device)
{
    StateProgramMemoPair *pair = spm_pair(device);
    NSData *constants = spm_constants(0), *launch = spm_launch(0);
    Token t = spm_move(96, 0, NO);
    spm_run(pair, t.word, 1, 1, constants, launch, NV2AMetalStateFull,
            spm_expected(constants, 96, launch.bytes), spm_written(96, YES), 1,
            1, YES, 0, NO);
    t = spm_move(97, 0, NO);
    spm_run(pair, t.word, 1, 1, constants, launch, NV2AMetalStateFull,
            spm_expected(constants, 97, launch.bytes), spm_written(97, YES), 1,
            1, YES, 0, NO);
    Token valid = t;
    for (unsigned bad = 0; bad < 4; bad++) {
        t = valid;
        if (bad == 0)
            t.word[1] |= 15u << 21;
        if (bad == 1)
            source(&t, 0, 0, 0, 0xe4);
        if (bad == 2)
            t.word[3] &= ~1u;
        if (bad == 3)
            t.word[3] |= 1u << 11;
        spm_run(pair, t.word, 1, 1, constants, launch, NV2AMetalStateFull, nil,
                nil, 1, 0, NO, 0, NO);
        t = valid;
        spm_run(pair, t.word, 1, 1, constants, launch, NV2AMetalStateFull,
                spm_expected(constants, 97, launch.bytes), spm_written(97, YES),
                0, 0, YES, 0, NO);
    }
    spm_run(pair, NULL, 1, 0, constants, launch, NV2AMetalStateFull, nil, nil,
            1, 0, NO, 0, NO);
    NSData *shortConstants = [constants subdataWithRange:NSMakeRange(0, 3071)];
    NSData *shortLaunch = [launch subdataWithRange:NSMakeRange(0, 15)];
    spm_run(pair, NULL, 1, 0, shortConstants, launch, NV2AMetalStateFull, nil,
            nil, 0, 0, NO, 0, NO);
    spm_run(pair, NULL, 1, 0, constants, shortLaunch, NV2AMetalStateFull, nil,
            nil, 0, 0, NO, 0, NO);
    spm_run(pair, NULL, 1, 0, constants, launch, (NV2AMetalStateAccess)2, nil,
            nil, 0, 0, NO, 0, NO);
}
static void spm_access(id<MTLDevice> device)
{
    StateProgramMemoPair *pair = spm_pair(device);
    Token t = spm_move(96, 95, YES);
    for (unsigned i = 0; i < 4; i++) {
        NSData *constants = spm_constants(i), *launch = spm_launch(i % 3);
        BOOL full = i != 1;
        spm_run(pair, t.word, 1, 1, constants, launch,
                full ? NV2AMetalStateFull : NV2AMetalStateUserOnly,
                full ?
                    spm_expected(constants, 96,
                                 (const uint8_t *)constants.bytes + 95 * 16) :
                    nil,
                full ? spm_written(96, YES) : nil, !i, !i, YES, 0, NO);
    }
    const unsigned rows[] = { 58, 59, 95, 96, 191 };
    for (unsigned i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
        NSData *constants = spm_constants(0), *launch = spm_launch(1);
        t = spm_move(rows[i], 0, NO);
        spm_run(pair, t.word, 1, 1, constants, launch, NV2AMetalStateFull,
                spm_expected(constants, rows[i], launch.bytes),
                spm_written(rows[i], YES), 1, 1, YES, 0, NO);
        BOOL allowed = rows[i] != 95;
        spm_run(pair, t.word, 1, 1, constants, launch, NV2AMetalStateUserOnly,
                allowed ? spm_expected(constants, rows[i], launch.bytes) : nil,
                allowed ? spm_written(rows[i], YES) : nil, 0, 0, YES, 0, NO);
    }
}
static void spm_fault_repair(id<MTLDevice> device)
{
    StateProgramMemoPair *pair = spm_pair(device);
    NSData *constants = spm_constants(0);
    Token t[3] = { spm_move(127, 0, NO), token(13, 0, 0),
                   spm_move(190, 96, YES) };
    t[0].word[3] &= ~1u;
    source(&t[1], 0, 2, 0, 0xe4);
    t[2].word[3] |= 2; // Relative constant read after ARL(v0.x).
    const unsigned profiles[] = { 0, 3, 4, 1, 2 };
    for (unsigned i = 0; i < sizeof(profiles) / sizeof(profiles[0]); i++) {
        NSData *launch = spm_launch(profiles[i]);
        BOOL allowed = profiles[i] != 3 && profiles[i] != 4;
        NSMutableData *expected = [constants mutableCopy];
        uint32_t flags[192] = { 0 };
        if (allowed) {
            unsigned address = profiles[i] == 0 ? 1 : profiles[i] == 1 ? 2 : 0;
            memcpy((uint8_t *)expected.mutableBytes + 127 * 16, launch.bytes,
                   16);
            memcpy((uint8_t *)expected.mutableBytes + 190 * 16,
                   (const uint8_t *)constants.bytes + (96 + address) * 16, 16);
            flags[127] = flags[190] = 1;
        }
        spm_run(pair, t[0].word, 3, 3, constants, launch, NV2AMetalStateFull,
                allowed ? expected : nil,
                allowed ? [NSData dataWithBytes:flags length:sizeof(flags)] :
                          nil,
                !i, !i, YES, 0, NO);
    }
}
static void spm_gpu_optional(id<MTLDevice> device)
{
    StateProgramMemoPair *pair = spm_pair(device);
    NSData *constants = spm_constants(0), *launch = spm_launch(0);
    Token t = spm_move(96, 0, NO);
    NSData *expected = spm_expected(constants, 96, launch.bytes);
    NSData *flags = spm_written(96, YES);
    pair.candidate.rejectMirror = YES;
    spm_run(pair, t.word, 1, 1, constants, launch, NV2AMetalStateFull, expected,
            flags, 1, 1, YES, 0, NO);
    assert(!pair.candidate.lastMirror);
    spm_run(pair, t.word, 1, 1, constants, launch, NV2AMetalStateFull, expected,
            flags, 0, 1, YES, 0, NO);
    assert(pair.candidate.lastMirror);
    spm_run(pair, t.word, 1, 1, constants, launch, NV2AMetalStateFull, expected,
            flags, 0, 0, YES, 0, NO);
    spm_run(pair, t.word, 1, 1, constants, launch, NV2AMetalStateFull, expected,
            flags, 0, 1, YES, 0, YES);
    spm_run(pair, t.word, 1, 1, constants, launch, NV2AMetalStateFull, expected,
            flags, 0, 0, YES, 0, NO);
}
static void spm_cpu_optional(id<MTLDevice> device)
{
    for (unsigned copy = 1; copy <= 2; copy++) {
        StateProgramMemoPair *pair = spm_pair(device);
        NSData *constants = spm_constants(0), *launch = spm_launch(0);
        Token t = spm_move(96, 0, NO);
        NSData *expected = spm_expected(constants, 96, launch.bytes);
        NSData *flags = spm_written(96, YES);
        pair.candidate.rejectCopy = copy;
        spm_run(pair, t.word, 1, 1, constants, launch, NV2AMetalStateFull,
                expected, flags, 1, 1, YES, 0, NO);
        spm_run(pair, t.word, 1, 1, constants, launch, NV2AMetalStateFull,
                expected, flags, 1, 1, YES, 0, NO);
        spm_run(pair, t.word, 1, 1, constants, launch, NV2AMetalStateFull,
                expected, flags, 0, 0, YES, 0, NO);
    }
}
static void spm_lifetime(id<MTLDevice> device)
{
    __weak id<MTLBuffer> mirror = nil;
    @autoreleasepool {
        StateProgramMemoPair *pair = spm_pair(device);
        NSData *constants = spm_constants(0), *launch = spm_launch(0);
        Token maximum[136];
        for (unsigned i = 0; i < 135; i++)
            maximum[i] = spm_nop(NO);
        maximum[135] = spm_move(191, 0, NO);
        NSData *expected = spm_expected(constants, 191, launch.bytes);
        NSData *flags = spm_written(191, YES);
        spm_run(pair, maximum[0].word, 136, 136, constants, launch,
                NV2AMetalStateFull, expected, flags, 1, 1, YES, 0, NO);
        mirror = pair.candidate.lastMirror;
        assert(mirror &&
               mirror.length == 136 * sizeof(NV2AMetalProgramInstruction));
        for (unsigned i = 0; i < 9; i++)
            spm_run(pair, maximum[0].word, 136, 136, constants, launch,
                    NV2AMetalStateFull, expected, flags, 0, 0, YES, 0, NO);
        for (unsigned kind = 1; kind <= 2; kind++) {
            spm_run(pair, maximum[0].word, 136, 136, constants, launch,
                    NV2AMetalStateFull, nil, nil, 0, 0, NO, kind, NO);
            spm_run(pair, maximum[0].word, 136, 136, constants, launch,
                    NV2AMetalStateFull, expected, flags, 0, 0, YES, 0, NO);
        }
        memset(maximum, 0, sizeof(maximum));
        Token *fresh = calloc(136, sizeof(Token));
        assert(fresh);
        for (unsigned i = 0; i < 135; i++)
            fresh[i] = spm_nop(NO);
        fresh[135] = spm_move(191, 0, NO);
        spm_run(pair, fresh[0].word, 136, 136, constants, launch,
                NV2AMetalStateFull, expected, flags, 0, 0, YES, 0, NO);
        free(fresh);
        spm_old_results(pair);
        pair = nil;
    }
    assert(!mirror);
}

static void state_program_memo_tests(id<MTLDevice> device)
{
    Method upload = class_getInstanceMethod(
        NV2AMetalCommands.class, @selector(uploadBytes:length:offset:error:));
    Method resource = class_getInstanceMethod(NV2AMetalCommands.class,
                                              @selector(addResource:error:));
    Method data =
        class_getClassMethod(NSData.class, @selector(dataWithBytes:length:));
    assert(upload && resource && data);
    spm_original_upload = (void *)method_getImplementation(upload);
    spm_original_resource = (void *)method_getImplementation(resource);
    spm_original_data = (void *)method_getImplementation(data);
    method_setImplementation(upload, (IMP)spm_upload);
    method_setImplementation(resource, (IMP)spm_resource);
    method_setImplementation(data, (IMP)spm_data);
    @try {
        @autoreleasepool {
            spm_repeated(device);
        }
        @autoreleasepool {
            spm_guardpages(device);
        }
        @autoreleasepool {
            spm_mutation(device);
        }
        @autoreleasepool {
            spm_access(device);
        }
        @autoreleasepool {
            spm_fault_repair(device);
        }
        @autoreleasepool {
            spm_gpu_optional(device);
        }
        @autoreleasepool {
            spm_cpu_optional(device);
        }
        @autoreleasepool {
            spm_lifetime(device);
        }
        puts("Metal4 State program memo:8 original-decoder/upload groups;"
             "whole constants/dirty,guardpage END prefixes,mutable tokens,"
             "fresh inputs/apertures,ARL repair,simulated optional OOM/"
             "registration fallbacks and owner lifetime PASS");
    } @finally {
        spm_work = NULL;
        spm_copyOrdinal = spm_copyFail = 0;
        method_setImplementation(upload, (IMP)spm_original_upload);
        method_setImplementation(resource, (IMP)spm_original_resource);
        method_setImplementation(data, (IMP)spm_original_data);
    }
}
#endif
