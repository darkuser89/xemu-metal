/* Bounded decoded-program working sets and unsubmitted GPU ownership.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_PROGRAM_LRU_H
#define TEST_METAL_PROGRAM_LRU_H
#import "hw/xbox/nv2a/pgraph/metal/lru-cache.h"
#include <time.h>

@interface NV2AMetalWritableProgram (ProgramLRUTest)
- (id)programForTokens:(const uint32_t *)tokens
                length:(NSUInteger)length
                 error:(NSError **)error;
@end
static NSUInteger program_lru_counter(id p, NSString *key)
{
    return [[p valueForKey:key] unsignedIntegerValue];
}
static void program_lru_tokens(Token tokens[2], unsigned row)
{
    tokens[0] = token(1, 0, row);
    source(&tokens[0], 0, 2, 0, 0xe4);
    destination(&tokens[0], 0x170, 15, 0, 0, 0, 0);
    tokens[1] = token(1, 0, row);
    source(&tokens[1], 0, 3, 0, 0xe4);
    destination(&tokens[1], 0x173, 15, 0, 0, 0, 0);
    tokens[1].word[3] |= 1;
}
static double program_lru_clock(void)
{
    struct timespec t;
    assert(!clock_gettime(CLOCK_MONOTONIC, &t));
    return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
}
static int program_lru_compare(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static void program_lru_tests(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    NV2AMetalWritableProgram *program =
        [[NV2AMetalWritableProgram alloc] initWithDevice:commands.device
                                                   error:&error];
    require(program != nil, error);
    NV2AMetalLRUCache *cache = [program valueForKey:@"programs"];
    NV2AMetalProgramUniforms u = uniforms();
    NV2AMetalProgramInput input;
    writable_input(&input, 0);
    id<MTLBuffer> inputBuffer =
        [commands.device newBufferWithBytes:&input
                                     length:sizeof(input)
                                    options:MTLResourceStorageModeShared];
    assert(inputBuffer);
    NSHashTable *buffers = [NSHashTable weakObjectsHashTable];
    NSMutableArray<NV2AMetalWritableEncoding *> *encodings =
        [NSMutableArray new];
    NSMutableArray<NSNumber *> *rows = [NSMutableArray new];
    require([commands beginWithError:&error] != nil, error);
    for (unsigned call = 0; call < 216; call++) {
        @autoreleasepool {
            unsigned row =
                call < 192 ? (call & 1 ? 0 : call / 2) : call - 192 + 72;
            Token tokens[2];
            program_lru_tokens(tokens, row);
            NV2AMetalWritableEncoding *encoding =
                [program encodeTokens:tokens[0].word
                               length:2
                             uniforms:&u
                      attributeBuffer:inputBuffer
                                first:0
                                count:1
                               access:1
                          writeEnable:NO
                            rasterize:YES
                             commands:commands
                                error:&error];
            require(encoding != nil, error);
            [encodings addObject:encoding];
            [rows addObject:@(row)];
            [buffers
                addObject:program_cache_buffer(program_cache_entry(program))];
            assert(cache.count <= 64);
        }
    }
    assert(cache.count == 64 && cache.evictionCount == 32 &&
           cache.missCount == 96);
    assert(cache.hitCount == 119 &&
           program_lru_counter(program, @"programFastHits") == 1);
    assert(program_lru_counter(program, @"programDecodeCount") == 96);
    assert(program_lru_counter(program, @"programBufferRequests") == 96);
    @autoreleasepool {
        assert(buffers.allObjects.count == 96);
    }
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    @autoreleasepool {
        assert(buffers.allObjects.count == 64);
    }
    for (unsigned i = 0; i < encodings.count; i++) {
        NV2AMetalWritableResult *result =
            [encodings[i] resolveWithError:&error];
        require(result != nil, error);
        unsigned row = rows[i].unsignedIntValue;
        const NV2AMetalProgramOutput *raw = result.registers.contents;
        assert(!raw[0].fault);
        assert(!memcmp(raw[0].registers[0], input.attributes[0], 16));
        assert(!memcmp(raw[0].registers[3], u.constants[row], 16));
        assert(
            !memcmp(result.constants.bytes, u.constants, sizeof(u.constants)));
        const uint32_t *dirty = result.written.bytes;
        for (unsigned r = 0; r < 192; r++)
            assert(!dirty[r]);
    }
    /* An invalid cold program at capacity must not evict the old working set.
     */
    Token invalid[2];
    program_lru_tokens(invalid, 150);
    invalid[0].word[1] = (invalid[0].word[1] & ~(15u << 21)) | 15u << 21;
    id last = program_cache_entry(program);
    NSUInteger requests =
        program_lru_counter(program, @"programBufferRequests");
    assert(![program programForTokens:invalid[0].word length:2 error:&error]);
    assert(error && cache.count == 64 && cache.evictionCount == 32 &&
           program_cache_entry(program) == last &&
           program_lru_counter(program, @"programBufferRequests") == requests);
    /* Row1 was evicted; rebuilding it inserts exactly one program. */
    Token evicted[2];
    program_lru_tokens(evicted, 1);
    require([program programForTokens:evicted[0].word length:2
                                error:&error] != nil,
            error);
    assert(cache.count == 64 && cache.evictionCount == 33 &&
           program_lru_counter(program, @"programBufferRequests") ==
               requests + 1);
    puts("Program LRU: 216 queued draws/96 distinct programs,120 hits/96 "
         "decodes/"
         "96 instruction buffers/32 evictions;64 cache owners,96 buffers "
         "retained "
         "before completion and64 after;raw positions/colors,constants/dirty "
         "masks,"
         "invalid-cold rollback and evicted-program rebuild PASS");

    /* Replacing/destroying the owner before submit cannot free its
     * instructions. */
    __weak id<MTLBuffer> survivor;
    NV2AMetalWritableEncoding *retained;
    require([commands beginWithError:&error] != nil, error);
    @autoreleasepool {
        NV2AMetalWritableProgram *temporary =
            [[NV2AMetalWritableProgram alloc] initWithDevice:commands.device
                                                       error:&error];
        require(temporary != nil, error);
        Token t[2];
        program_lru_tokens(t, 96);
        retained = [temporary encodeTokens:t[0].word
                                    length:2
                                  uniforms:&u
                           attributeBuffer:inputBuffer
                                     first:0
                                     count:1
                                    access:1
                               writeEnable:NO
                                 rasterize:NO
                                  commands:commands
                                     error:&error];
        require(retained != nil, error);
        survivor = program_cache_buffer(program_cache_entry(temporary));
    }
    @autoreleasepool {
        assert(survivor != nil);
    }
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    assert(!survivor);
    NV2AMetalWritableResult *retainedResult =
        [retained resolveWithError:&error];
    require(retainedResult != nil, error);
    const NV2AMetalProgramOutput *retainedRaw =
        retainedResult.registers.contents;
    assert(!memcmp(retainedRaw[0].registers[3], u.constants[96], 16));

    /* Maximum declared length bounds payload independently of instruction data.
     * Device allocatedSize is reported separately, not inferred from length. */
    NSUInteger tokenBytes = 0, decodedBytes = 0, allocatedBytes = 0;
    @autoreleasepool {
        NV2AMetalWritableProgram *maximum =
            [[NV2AMetalWritableProgram alloc] initWithDevice:commands.device
                                                       error:&error];
        require(maximum != nil, error);
        NSMutableSet *hashes = [NSMutableSet new];
        for (unsigned p = 0; p < 64; p++) {
            Token longTokens[NV2A_METAL_VP_SLOTS];
            for (unsigned slot = 0; slot < NV2A_METAL_VP_SLOTS; slot++) {
                longTokens[slot] = token(1, 0, p);
                source(&longTokens[slot], 0, 3, 0, 0xe4);
                destination(&longTokens[slot], 0x173, 15, 0, 0, 0, 0);
            }
            longTokens[NV2A_METAL_VP_SLOTS - 1].word[3] |= 1;
            id entry = [maximum programForTokens:longTokens[0].word
                                          length:NV2A_METAL_VP_SLOTS
                                           error:&error];
            require(entry != nil, error);
            tokenBytes += [[entry valueForKey:@"tokens"] length];
            decodedBytes += program_cache_buffer(entry).length;
            allocatedBytes += program_cache_buffer(entry).allocatedSize;
        }
        NV2AMetalLRUCache *maximumCache = [maximum valueForKey:@"programs"];
        NSDictionary *nodes = [maximumCache valueForKey:@"entries"];
        for (id key in nodes)
            [hashes addObject:@([key hash])];
        assert(maximumCache.count == 64 && hashes.count == 64);
        assert(tokenBytes == 64 * 136 * 16 && decodedBytes == 64 * 136 * 56);
    }
    printf("Program LRU budget:64 maximum-length entries, %lu token bytes + "
           "%lu decoded buffer bytes = %lu logical payload bytes;GPU buffers "
           "report %lu allocated bytes (excludes host objects);owner-release "
           "GPU PASS\n",
           (unsigned long)tokenBytes, (unsigned long)decodedBytes,
           (unsigned long)(tokenBytes + decodedBytes),
           (unsigned long)allocatedBytes);

    NV2AMetalWritableProgram *wide =
        [[NV2AMetalWritableProgram alloc] initWithDevice:commands.device
                                                   error:&error];
    NV2AMetalWritableProgram *single =
        [[NV2AMetalWritableProgram alloc] initWithDevice:commands.device
                                                   error:&error];
    require(wide && single, error);
    [single setValue:[[NV2AMetalLRUCache alloc] initWithCapacity:1]
              forKey:@"programs"];
    Token working[16][2];
    for (unsigned i = 0; i < 16; i++) {
        program_lru_tokens(working[i], i);
        require([wide programForTokens:working[i][0].word
                                length:2
                                 error:&error] != nil,
                error);
        require([single programForTokens:working[i][0].word
                                  length:2
                                   error:&error] != nil,
                error);
    }
    double times[2][7];
    NSUInteger initialRequests[2] = {
        program_lru_counter(wide, @"programBufferRequests"),
        program_lru_counter(single, @"programBufferRequests")
    };
    for (unsigned pair = 0; pair < 9; pair++) {
        for (unsigned order = 0; order < 2; order++) {
            unsigned mode = (pair + order) & 1;
            NV2AMetalWritableProgram *p = mode ? single : wide;
            double start = program_lru_clock();
            for (unsigned n = 0; n < 512; n++) {
                @autoreleasepool {
                    id entry = [p programForTokens:working[n % 16][0].word
                                            length:2
                                             error:&error];
                    require(entry != nil, error);
                    assert([[entry valueForKey:@"tokens"]
                        isEqualToData:[NSData
                                          dataWithBytes:working[n % 16]
                                                 length:sizeof(working[0])]]);
                }
            }
            double ms = program_lru_clock() - start;
            if (pair >= 2)
                times[mode][pair - 2] = ms;
        }
    }
    assert(program_lru_counter(wide, @"programBufferRequests") ==
           initialRequests[0]);
    assert(program_lru_counter(single, @"programBufferRequests") ==
           initialRequests[1] + 9 * 512);
    assert(program_lru_counter(wide, @"programDecodeCount") == 16);
    assert(program_lru_counter(single, @"programDecodeCount") == 16 + 9 * 512);
    for (unsigned mode = 0; mode < 2; mode++)
        qsort(times[mode], 7, sizeof(double), program_lru_compare);
    printf(
        "Program LRU isolated 512-lookups median64-entry/1-entry=%.6f/%.6f ms;"
        "16-program cycle,2 warmups/7 alternating pairs,0/4608 new instruction "
        "buffers across9 pairs;comparison changes only cache capacity,not an "
        "old binary\n",
        times[0][3], times[1][3]);
}
#endif
