/* Borrowed program lookup versus the original owning-key lookup.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_PROGRAM_KEY_REUSE_H
#define TEST_METAL_PROGRAM_KEY_REUSE_H
#import <objc/runtime.h>

@interface NV2AMetalProgramKey : NSObject <NSCopying>
@property(nonatomic, readonly) NSData *tokens;
- (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)length;
- (instancetype)initLookup;
- (void)setLookupBytes:(const void *)bytes length:(NSUInteger)length;
- (void)clearLookupBytes;
@end
@interface NV2AMetalWritableProgram (ProgramKeyReuseTest)
- (id)programForTokens:(const uint32_t *)tokens
                length:(NSUInteger)length
      validatedProgram:(NV2AMetalValidatedProgram *)validated
                 error:(NSError **)error;
@end
static _Thread_local BOOL pkr_active, pkr_fallback, pkr_fail_snapshot;
static _Thread_local NSUInteger pkr_owned, pkr_payloads, pkr_lookups, pkr_sets;
static _Thread_local const void *pkr_snapshot_bytes;
static _Thread_local NSUInteger pkr_snapshot_length;
static id (*pkr_data_original)(id, SEL, const void *, NSUInteger);
static id pkr_data(id cls, SEL selector, const void *bytes, NSUInteger length)
{
    if (pkr_active && pkr_snapshot_bytes == bytes &&
        pkr_snapshot_length == length) {
        pkr_payloads++;
        if (pkr_fail_snapshot)
            return nil;
    }
    return pkr_data_original(cls, selector, bytes, length);
}
@interface NV2AMetalProgramKey (ProgramKeyReuseTest)
- (instancetype)pkr_initWithBytes:(const void *)bytes
                           length:(NSUInteger)length
    __attribute__((objc_method_family(init)));
- (instancetype)pkr_initLookup __attribute__((objc_method_family(init)));
- (void)pkr_setLookupBytes:(const void *)bytes length:(NSUInteger)length;
@end
@implementation NV2AMetalProgramKey (ProgramKeyReuseTest)
- (instancetype)pkr_initWithBytes:(const void *)bytes length:(NSUInteger)length
{
    const void *saved = pkr_snapshot_bytes;
    NSUInteger savedLength = pkr_snapshot_length;
    if (pkr_active) {
        pkr_owned++;
        pkr_snapshot_bytes = bytes;
        pkr_snapshot_length = length;
    }
    @try {
        self = [self pkr_initWithBytes:bytes length:length];
        return self;
    } @finally {
        pkr_snapshot_bytes = saved;
        pkr_snapshot_length = savedLength;
    }
}
- (instancetype)pkr_initLookup
{
    self = [self pkr_initLookup];
    if (pkr_active) {
        pkr_lookups++;
        if (pkr_fallback)
            return nil;
    }
    return self;
}
- (void)pkr_setLookupBytes:(const void *)bytes length:(NSUInteger)length
{
    if (pkr_active && length)
        pkr_sets++;
    [self pkr_setLookupBytes:bytes length:length];
}
@end
static void pkr_scope(BOOL fallback)
{
    pkr_owned = pkr_payloads = pkr_lookups = pkr_sets = 0;
    pkr_fallback = fallback;
    pkr_active = YES;
}
static void pkr_exchange(SEL a, SEL b)
{
    Method original = class_getInstanceMethod(NV2AMetalProgramKey.class, a);
    Method replacement = class_getInstanceMethod(NV2AMetalProgramKey.class, b);
    assert(original && replacement);
    method_exchangeImplementations(original, replacement);
}
static NV2AMetalWritableProgram *pkr_program(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalWritableProgram *p =
        [[NV2AMetalWritableProgram alloc] initWithDevice:device error:&error];
    require(p != nil, error);
    return p;
}
static void pkr_finish(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
}
static void pkr_cleared(NV2AMetalWritableProgram *program, BOOL fallback)
{
    id lookup = [program valueForKey:@"programLookupKey"];
    if (fallback) {
        assert(!lookup);
        return;
    }
    assert(lookup && ![lookup tokens]);
    Ivar pointerIvar =
        class_getInstanceVariable(NV2AMetalProgramKey.class, "_lookupBytes");
    assert(pointerIvar);
    const void *borrowed = NULL;
    const uint8_t *object = (__bridge const void *)lookup;
    memcpy(&borrowed, object + ivar_getOffset(pointerIvar), sizeof(borrowed));
    assert(!borrowed && ![[lookup valueForKey:@"length"] unsignedIntegerValue]);
    NV2AMetalProgramKey *empty = [[NV2AMetalProgramKey alloc] initWithBytes:NULL
                                                                     length:0];
    assert([lookup hash] == empty.hash);
}
static NSData *pkr_result_bytes(NV2AMetalWritableResult *r,
                                const NV2AMetalProgramInput *input,
                                const NV2AMetalProgramUniforms *u, unsigned row)
{
    assert(r && r.vertexCount == 1 && r.registers && r.vertices);
    const NV2AMetalProgramOutput *raw = r.registers.contents;
    /* Byte-first independent execution oracle, before cache/allocation checks.
     */
    assert(!raw[0].fault &&
           !memcmp(raw[0].registers[0], input->attributes[0], 16) &&
           !memcmp(raw[0].registers[3], u->constants[row], 16));
    assert(!memcmp(r.constants.bytes, u->constants, sizeof(u->constants)));
    const uint32_t *written = r.written.bytes;
    for (unsigned i = 0; i < 192; i++)
        assert(!written[i]);
    NSMutableData *bytes = [NSMutableData data];
    [bytes appendBytes:raw length:sizeof(*raw)];
    [bytes appendBytes:r.vertices.contents length:sizeof(NV2AMetalVertex)];
    [bytes appendData:r.constants];
    [bytes appendData:r.written];
    return bytes;
}
static NSArray<NSData *> *pkr_working_set(id<MTLDevice> device, NSUInteger size,
                                          BOOL fallback)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(commands != nil, error);
    NV2AMetalWritableProgram *program = pkr_program(device);
    NV2AMetalProgramUniforms u = uniforms();
    NV2AMetalProgramInput input;
    writable_input(&input, 0);
    id<MTLBuffer> attributes =
        [device newBufferWithBytes:&input
                            length:sizeof(input)
                           options:MTLResourceStorageModeShared];
    assert(attributes);
    NSMutableArray<NV2AMetalWritableEncoding *> *encodings =
        [NSMutableArray new];
    NSUInteger owned[192], payloads[192], lookups[192], sets[192];
    assert(size <= 64);
    require([commands beginWithError:&error] != nil, error);
    for (NSUInteger i = 0; i < size * 3; i++) {
        Token tokens[2];
        program_lru_tokens(tokens, (unsigned)(i % size));
        pkr_scope(fallback);
        NV2AMetalWritableEncoding *encoding =
            [program encodeTokens:tokens[0].word
                           length:2
                         uniforms:&u
                  attributeBuffer:attributes
                            first:0
                            count:1
                           access:1
                      writeEnable:NO
                        rasterize:YES
                         commands:commands
                            error:&error];
        pkr_active = NO;
        require(encoding != nil, error);
        [encodings addObject:encoding];
        owned[i] = pkr_owned;
        payloads[i] = pkr_payloads;
        lookups[i] = pkr_lookups;
        sets[i] = pkr_sets;
    }
    pkr_finish(commands);
    NSMutableArray<NSData *> *outputs = [NSMutableArray new];
    for (NSUInteger i = 0; i < encodings.count; i++) {
        NV2AMetalWritableResult *r = [encodings[i] resolveWithError:&error];
        require(r != nil, error);
        [outputs
            addObject:pkr_result_bytes(r, &input, &u, (unsigned)(i % size))];
    }
    for (NSUInteger i = 0; i < encodings.count; i++) {
        NSUInteger copies = fallback || i < size ? 1 : 0;
        assert(owned[i] == copies && payloads[i] == copies);
        assert(lookups[i] == (fallback ? 1 : i == 0));
        assert(sets[i] == !fallback);
    }
    NV2AMetalLRUCache *cache = [program valueForKey:@"programs"];
    assert(cache.count == size && !cache.evictionCount &&
           cache.missCount == size && cache.hitCount == size * 2);
    assert(program_lru_counter(program, @"programDecodeCount") == size &&
           program_lru_counter(program, @"programBufferRequests") == size &&
           !program_lru_counter(program, @"programFastHits"));
    pkr_cleared(program, fallback);
    return outputs;
}
static NSArray<NSData *> *pkr_mutation(id<MTLDevice> device, BOOL fallback)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(commands != nil, error);
    NV2AMetalWritableProgram *program = pkr_program(device);
    NV2AMetalProgramUniforms u = uniforms();
    NV2AMetalProgramInput input;
    writable_input(&input, 1);
    id<MTLBuffer> attributes =
        [device newBufferWithBytes:&input
                            length:sizeof(input)
                           options:MTLResourceStorageModeShared];
    /* This live mutable owner survives every dispatch and GPU completion.
     * A no-copy key therefore fails by stale instructions, never by UAF. */
    NSMutableData *source = [NSMutableData dataWithLength:3 * sizeof(Token)];
    NSMutableArray<NV2AMetalWritableEncoding *> *encodings =
        [NSMutableArray new];
    NSMutableArray<NSData *> *snapshots = [NSMutableArray new];
    NSUInteger keyCopies[6], payloadCopies[6];
    const unsigned rows[] = { 1, 2, 2, 2, 2, 3 };
    const NSUInteger lengths[] = { 2, 2, 2, 3, 3, 2 };
    require([commands beginWithError:&error] != nil, error);
    for (unsigned i = 0; i < 6; i++) {
        Token *tokens = source.mutableBytes;
        program_lru_tokens(tokens, rows[i]);
        memset(&tokens[2], i == 4 ? 0xa5 : 0x5a, sizeof(tokens[2]));
        pkr_scope(fallback);
        NV2AMetalWritableEncoding *e = [program encodeTokens:tokens[0].word
                                                      length:lengths[i]
                                                    uniforms:&u
                                             attributeBuffer:attributes
                                                       first:0
                                                       count:1
                                                      access:1
                                                 writeEnable:NO
                                                   rasterize:YES
                                                    commands:commands
                                                       error:&error];
        pkr_active = NO;
        require(e != nil, error);
        keyCopies[i] = pkr_owned;
        payloadCopies[i] = pkr_payloads;
        [encodings addObject:e];
        [snapshots
            addObject:[program_cache_entry(program) valueForKey:@"tokens"]];
    }
    pkr_finish(commands);
    NSMutableArray<NSData *> *outputs = [NSMutableArray new];
    for (unsigned i = 0; i < 6; i++) {
        NV2AMetalWritableResult *r = [encodings[i] resolveWithError:&error];
        require(r != nil, error);
        [outputs addObject:pkr_result_bytes(r, &input, &u, rows[i])];
    }
    for (unsigned i = 0; i < 6; i++) {
        Token expected[3];
        program_lru_tokens(expected, rows[i]);
        memset(&expected[2], i == 4 ? 0xa5 : 0x5a, sizeof(expected[2]));
        assert([snapshots[i] length] == lengths[i] * sizeof(Token) &&
               !memcmp([snapshots[i] bytes], expected, [snapshots[i] length]));
        assert(keyCopies[i] == (i != 2) && payloadCopies[i] == (i != 2));
    }
    assert(program_lru_counter(program, @"programDecodeCount") == 5 &&
           program_lru_counter(program, @"programBufferRequests") == 5 &&
           program_lru_counter(program, @"programFastHits") == 1);
    pkr_cleared(program, fallback);
    return outputs;
}
static NSData *pkr_owner_release(id<MTLDevice> device, BOOL fallback)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(commands != nil, error);
    NV2AMetalProgramUniforms u = uniforms();
    NV2AMetalProgramInput input;
    writable_input(&input, 2);
    id<MTLBuffer> attributes =
        [device newBufferWithBytes:&input
                            length:sizeof(input)
                           options:MTLResourceStorageModeShared];
    NV2AMetalWritableEncoding *encoding;
    NSData *ownedTokens;
    __weak NV2AMetalWritableProgram *weakProgram;
    __weak NSMutableData *weakSource;
    Token expected[2];
    program_lru_tokens(expected, 7);
    require([commands beginWithError:&error] != nil, error);
    @autoreleasepool {
        NV2AMetalWritableProgram *program = pkr_program(device);
        NSMutableData *source = [NSMutableData dataWithBytes:expected
                                                      length:sizeof(expected)];
        weakProgram = program;
        weakSource = source;
        pkr_scope(fallback);
        encoding = [program encodeTokens:source.bytes
                                  length:2
                                uniforms:&u
                         attributeBuffer:attributes
                                   first:0
                                   count:1
                                  access:1
                             writeEnable:NO
                               rasterize:YES
                                commands:commands
                                   error:&error];
        pkr_active = NO;
        require(encoding != nil, error);
        ownedTokens = [program_cache_entry(program) valueForKey:@"tokens"];
        memset(source.mutableBytes, 0xa5, source.length);
        dispatch_queue_t specialization =
            [program valueForKey:@"specializationQueue"];
        dispatch_sync(specialization, ^{
                      });
    }
    pkr_finish(commands);
    NV2AMetalWritableResult *result = [encoding resolveWithError:&error];
    require(result != nil, error);
    NSData *bytes = pkr_result_bytes(result, &input, &u, 7);
    assert(!weakProgram && !weakSource &&
           ownedTokens.length == sizeof(expected) &&
           !memcmp(ownedTokens.bytes, expected, sizeof(expected)));
    return bytes;
}
static NSArray *pkr_order(NV2AMetalLRUCache *cache)
{
    NSMutableArray *keys = [NSMutableArray new];
    for (id entry = [cache valueForKey:@"oldest"]; entry;
         entry = [entry valueForKey:@"next"])
        [keys addObject:[entry valueForKey:@"key"]];
    return keys;
}
static void pkr_host(id<MTLDevice> device, BOOL fallback)
{
    NSError *error = nil;
    NV2AMetalWritableProgram *p = pkr_program(device);
    NV2AMetalLRUCache *cache = [p valueForKey:@"programs"];
    for (unsigned row = 0; row < 64; row++) {
        Token t[2];
        program_lru_tokens(t, row);
        pkr_scope(fallback);
        id entry = [p programForTokens:t[0].word length:2 error:&error];
        pkr_active = NO;
        require(entry != nil, error);
        assert(pkr_owned == 1 && pkr_payloads == 1);
    }
    Token t[2];
    program_lru_tokens(t, 0);
    pkr_scope(fallback);
    id promoted = [p programForTokens:t[0].word length:2 error:&error];
    pkr_active = NO;
    require(promoted != nil, error);
    assert(pkr_owned == fallback && pkr_payloads == fallback);
    NSArray *order = pkr_order(cache);
    assert(!memcmp([[order.lastObject tokens] bytes], t, sizeof(t)));
    id last = program_cache_entry(p);
    NSUInteger decodes = program_lru_counter(p, @"programDecodeCount");
    NSUInteger requests = program_lru_counter(p, @"programBufferRequests");
    NSUInteger misses = cache.missCount, hits = cache.hitCount;
    program_lru_tokens(t, 64);
    pkr_scope(fallback);
    pkr_fail_snapshot = YES;
    id failed = [p programForTokens:t[0].word length:2 error:&error];
    pkr_active = pkr_fail_snapshot = NO;
    assert(!failed &&
           [error.localizedDescription
               isEqualToString:@"Cannot snapshot native vertex program"]);
    assert(pkr_owned == 1 && pkr_payloads == 1 &&
           cache.missCount == misses + !fallback && cache.hitCount == hits &&
           [pkr_order(cache) isEqualToArray:order] && cache.count == 64 &&
           !cache.evictionCount && program_cache_entry(p) == last &&
           program_lru_counter(p, @"programDecodeCount") == decodes &&
           program_lru_counter(p, @"programBufferRequests") == requests);
    error = nil;
    pkr_scope(fallback);
    id added = [p programForTokens:t[0].word length:2 error:&error];
    pkr_active = NO;
    require(added != nil, error);
    NSArray *after = pkr_order(cache);
    assert(cache.count == 64 && cache.evictionCount == 1 &&
           after[62] == order[63] && after[0] == order[1]);
    /* Row1, not promoted row0, was evicted. The retained immutable keys remain
     * valid after every caller stack program has disappeared. */
    program_lru_tokens(t, 0);
    pkr_scope(fallback);
    id warmed = [p programForTokens:t[0].word length:2 error:&error];
    pkr_active = NO;
    require(warmed == promoted, error);
    assert(pkr_owned == fallback && pkr_payloads == fallback &&
           program_lru_counter(p, @"programDecodeCount") == decodes + 1);
    pkr_scope(fallback);
    id same = [p programForTokens:t[0].word length:2 error:&error];
    pkr_active = NO;
    assert(same == promoted && !pkr_owned && !pkr_payloads && !pkr_sets &&
           !pkr_lookups);
    Token other[2];
    program_lru_tokens(other, 1);
    NV2AMetalValidatedProgram *wrongMetadata =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:other[0].word
                                                   length:2
                                                    error:&error];
    require(wrongMetadata != nil, error);
    NSArray *metadataOrder = pkr_order(cache);
    uint64_t metadataHits = cache.hitCount, metadataMisses = cache.missCount;
    error = nil;
    pkr_scope(fallback);
    id invalidMetadata = [p programForTokens:t[0].word
                                      length:2
                            validatedProgram:wrongMetadata
                                       error:&error];
    pkr_active = NO;
    assert(!invalidMetadata && error && !pkr_owned && !pkr_payloads &&
           !pkr_sets && !pkr_lookups && cache.hitCount == metadataHits &&
           cache.missCount == metadataMisses &&
           [pkr_order(cache) isEqualToArray:metadataOrder] &&
           program_cache_entry(p) == promoted);
    pkr_cleared(p, fallback);

    /* Warm dispatch validation precedes both lookup and the last-entry path. */
    NV2AMetalProgramUniforms u = uniforms();
    NV2AMetalProgramInput input;
    writable_input(&input, 0);
    id<MTLBuffer> attributes =
        [device newBufferWithBytes:&input
                            length:sizeof(input)
                           options:MTLResourceStorageModeShared];
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(commands != nil, error);
    require([commands beginWithError:&error] != nil, error);
    for (unsigned invalid = 0; invalid < 3; invalid++) {
        NV2AMetalProgramUniforms bad = u;
        if (!invalid)
            bad.point_scale = 0;
        NSUInteger length = invalid == 2 ? 0 : 2;
        NSUInteger first = invalid == 1 ? NSUIntegerMax : 0;
        NSArray *before = pkr_order(cache);
        uint64_t hit = cache.hitCount, miss = cache.missCount;
        NSUInteger fast = program_lru_counter(p, @"programFastHits");
        error = nil;
        pkr_scope(fallback);
        NV2AMetalWritableEncoding *e = [p encodeTokens:t[0].word
                                                length:length
                                              uniforms:&bad
                                       attributeBuffer:attributes
                                                 first:first
                                                 count:1
                                                access:1
                                           writeEnable:NO
                                             rasterize:YES
                                              commands:commands
                                                 error:&error];
        pkr_active = NO;
        assert(
            !e && error && !pkr_owned && !pkr_payloads && !pkr_sets &&
            !pkr_lookups && cache.hitCount == hit && cache.missCount == miss &&
            program_lru_counter(p, @"programFastHits") == fast &&
            program_lru_counter(p, @"programDecodeCount") == decodes + 1 &&
            program_lru_counter(p, @"programBufferRequests") == requests + 1 &&
            [pkr_order(cache) isEqualToArray:before]);
    }
    [commands cancel];
}
static void pkr_keys(void)
{
    Token source[3];
    program_lru_tokens(source, 1);
    memset(&source[2], 0xab, sizeof(source[2]));
    NV2AMetalProgramKey *a =
        [[NV2AMetalProgramKey alloc] initWithBytes:source
                                            length:sizeof(source)];
    NV2AMetalProgramKey *b =
        [[NV2AMetalProgramKey alloc] initWithBytes:source
                                            length:sizeof(source)];
    NV2AMetalProgramKey *lookup = [[NV2AMetalProgramKey alloc] initLookup];
    assert(a && b && lookup && !lookup.tokens);
    [lookup setLookupBytes:source length:sizeof(source)];
    assert([a isEqual:lookup] && [lookup isEqual:a] && a.hash == lookup.hash);
    NV2AMetalProgramKey *ownedCopy = [lookup copy];
    assert(ownedCopy != lookup && ownedCopy.tokens && [ownedCopy isEqual:a]);
    /* Synthetic equal-hash unequal identities exercise dictionary EQ in both
     * directions; this is not a claim about naturally occurring collisions. */
    source[2].word[0] ^= 1;
    [lookup setLookupBytes:source length:sizeof(source)];
    [a setValue:@17 forKey:@"hash"];
    [b setValue:@17 forKey:@"hash"];
    [lookup setValue:@17 forKey:@"hash"];
    assert(![a isEqual:lookup] && ![lookup isEqual:a]);
    NSDictionary *stored = @{a : @1};
    assert([stored[b] isEqual:@1] && !stored[lookup]);
    [lookup setLookupBytes:source length:2 * sizeof(Token)];
    assert(![lookup isEqual:a] && ![a isEqual:lookup]);
    [lookup clearLookupBytes];
    assert([ownedCopy.tokens isEqualToData:a.tokens] &&
           [a.tokens isEqualToData:b.tokens] &&
           a.tokens.length == sizeof(source));
    memset(source, 0, sizeof(source));
    assert([ownedCopy.tokens isEqualToData:a.tokens]);
    NV2AMetalProgramKey *empty = [[NV2AMetalProgramKey alloc] initWithBytes:NULL
                                                                     length:0];
    assert([lookup isEqual:empty] && [empty isEqual:lookup] &&
           lookup.hash == empty.hash);
}
static void program_key_reuse_tests(NV2AMetalCommands *commands)
{
    Method factory =
        class_getClassMethod(NSData.class, @selector(dataWithBytes:length:));
    assert(factory);
    pkr_data_original = (void *)method_getImplementation(factory);
    pkr_exchange(@selector(initWithBytes:length:),
                 @selector(pkr_initWithBytes:length:));
    pkr_exchange(@selector(initLookup), @selector(pkr_initLookup));
    pkr_exchange(@selector(setLookupBytes:length:),
                 @selector(pkr_setLookupBytes:length:));
    method_setImplementation(factory, (IMP)pkr_data);
    @try {
        /* First: the no-copy negative control must encounter only live,
         * mutable token storage before its GPU byte oracle. */
        NSArray *candidate = pkr_mutation(commands.device, NO);
        NSArray *reference = pkr_mutation(commands.device, YES);
        assert([candidate isEqualToArray:reference]);
        for (NSUInteger size = 16; size <= 64; size *= 4) {
            NSArray *working = pkr_working_set(commands.device, size, NO);
            NSArray *old = pkr_working_set(commands.device, size, YES);
            assert([working isEqualToArray:old]);
        }
        NSData *released = pkr_owner_release(commands.device, NO);
        NSData *legacyReleased = pkr_owner_release(commands.device, YES);
        assert([released isEqualToData:legacyReleased]);
        pkr_host(commands.device, NO);
        pkr_host(commands.device, YES);
        pkr_keys();
    } @finally {
        pkr_active = pkr_fail_snapshot = pkr_fallback = NO;
        method_setImplementation(factory, (IMP)pkr_data_original);
        pkr_exchange(@selector(setLookupBytes:length:),
                     @selector(pkr_setLookupBytes:length:));
        pkr_exchange(@selector(initLookup), @selector(pkr_initLookup));
        pkr_exchange(@selector(initWithBytes:length:),
                     @selector(pkr_initWithBytes:length:));
    }
    puts("Program key reuse:16/64 programs,480 queued GPU outputs+12 "
         "mutable-source+2 owner-release outputs exact against owning "
         "fallback; warm "
         "key/payload copies1->0,full-byte identity,collision symmetry,lookup "
         "clearing/copy,OOM rollback,LRU promotion and invalid-warm guards "
         "PASS");
}
#endif
