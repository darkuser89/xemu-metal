/* Readonly static fault proof versus the native generic interpreter.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_FAULT_FREE_READONLY_H
#define TEST_METAL_FAULT_FREE_READONLY_H
#import "hw/xbox/nv2a/pgraph/metal/vertex-fetch.h"
static unsigned proof_cases, proof_safe, proof_captured, proof_faults;
static void proof_finish(NV2AMetalCommands *commands, NSArray *encodings,
                         NSArray *programs, NSArray *accesses,
                         NSArray *expected)
{
    NSError *error = nil;
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    for (NSUInteger i = 0; i < encodings.count; i++) {
        NV2AMetalWritableEncoding *encoded = encodings[i];
        NV2AMetalValidatedProgram *program = programs[i];
        BOOL safe =
            [program hasFaultFreeReadOnlyAccess:[accesses[i] unsignedIntValue]];
        unsigned flags = [expected[i] unsignedIntValue];
        assert(safe == !!(flags & 1));
        NV2AMetalWritableResult *actual = [encoded resolveWithError:&error];
        if (flags & 2) {
            require(actual != nil, error);
            assert(actual.vertexCount == 4 && !actual.registers &&
                   actual.vertices);
            for (unsigned row = 0; row < 192; row++)
                assert(!((const uint32_t *)actual.written.bytes)[row]);
            proof_safe += safe;
            proof_captured += !safe;
        }
        proof_faults += !actual;
        proof_cases++;
    }
}
static void attribute_readonly_tests(NV2AMetalCommands *commands,
                                     NV2AMetalWritableProgram *program)
{
    enum {
        UB = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
        S1 = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1,
        RAW = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K,
        F = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        CMP = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP
    };
    static const struct AttributeCase {
        unsigned format, bits, lane, base, access;
        BOOL zeroStride, indexed, overflow, scaled, pending, valid;
        float scale;
    } cases[] = {
        { UB, 255, 0, 96, .pending = YES, .valid = YES },
        { UB, 255, 0, 191, .valid = NO },
        { S1, 0x8000, 0, 97, .pending = YES, .valid = YES },
        { S1, 0x8000, 0, 96, .valid = NO },
        { S1, 0x8000, 0, 96, 1, .pending = YES, .valid = YES },
        { RAW, 0x8000, 0, 97, .valid = NO },
        { RAW, 0x8000, 3, 190, .pending = YES, .valid = YES },
        { F, 0x7fc12345, 0, 96, .valid = NO },
        { F, 0x7fc12345, 3, 190, .pending = YES, .valid = YES },
        { F, 0x3e800000, 0, 96, .valid = YES },
        { CMP, 512u << 22, 2, 98, .pending = YES, .valid = YES },
        { CMP, 512u << 22, 2, 97, .valid = NO },
        { CMP, 512u << 22, 2, 97, .zeroStride = YES, .pending = YES,
          .valid = YES },
        { UB, 255, 0, 96, .indexed = YES, .overflow = YES },
        { UB, 255, 0, 96, .indexed = YES, .pending = YES, .valid = YES },
        { UB, 255, 0, 96, .scaled = YES, .pending = YES, .valid = YES },
        { RAW, 0x8000, 0, 128, .scaled = YES, .pending = YES,
          .valid = YES, .scale = 0x1p-10f },
        { RAW, 0x7fff, 0, 128, .scaled = YES, .pending = YES,
          .valid = YES, .scale = 0x1p-10f },
        { RAW, 0x8000, 0, 127, .scaled = YES,
          .valid = NO, .scale = 0x1p-10f },
    };
    NSError *error = nil;
    NV2AMetalVertexFetch *fetch =
        [[NV2AMetalVertexFetch alloc] initWithDevice:commands.device
                                               error:&error];
    require(fetch != nil, error);
    unsigned admitted = 0, faults = 0;
    const size_t caseCount = sizeof(cases) / sizeof(cases[0]);
    for (size_t i = 0; i < caseCount; i++) {
        @autoreleasepool {
            const struct AttributeCase *c = &cases[i];
            uint32_t raw[] = { c->bits, c->bits, c->bits };
            __attribute__((objc_precise_lifetime)) id<MTLBuffer> sourceBuffer =
                [commands.device
                    newBufferWithBytes:raw
                                length:sizeof(raw)
                               options:MTLResourceStorageModeShared];
            const uint32_t index = c->overflow ? UINT32_MAX : 0;
            const uint32_t indices[] = { index, index, index };
            id<MTLBuffer> indexBuffer =
                c->indexed ?
                    [commands.device
                        newBufferWithBytes:indices
                                    length:sizeof(indices)
                                   options:MTLResourceStorageModeShared] :
                    nil;
            assert(sourceBuffer && (!c->indexed || indexBuffer));
            const unsigned attribute = NV2A_METAL_VP_ATTRIBUTES - 1;
            NV2AMetalAttributeSource sources[16] = { 0 };
            sources[0].inline_value[3] = 1;
            sources[attribute] = (NV2AMetalAttributeSource){
                .buffer = sourceBuffer,
                .format = c->format,
                .count = 1,
                .stride = c->zeroStride ? 0 : 4,
                .inline_value = { c->overflow ? 1024 : 0.25f, 0, 0, 1 },
            };
            require([commands beginWithError:&error] != nil, error);
            NV2AMetalFetchResult *frozen =
                [fetch encodeSources:sources
                               count:3
                         firstVertex:c->indexed ? 1 : 0
                             indices:indexBuffer
                         indexOffset:0
                           indexSize:c->indexed ? 4 : 0
                       currentVertex:0
                      skippingPrefix:1
                            commands:commands
                               error:&error];
            require(frozen != nil, error);
            assert(frozen.vertexCount == 2 && frozen.hasCurrent);
            sources[attribute].format = F;
            sources[attribute].inline_value[0] = 4096;
            NV2AMetalFetchUniforms proof;
            assert([frozen getSourceUniforms:&proof
                             attributeBuffer:frozen.attributes
                                       first:1
                                       count:1
                                    commands:commands]);
            assert(proof.attributes[attribute].format == c->format &&
                   proof.attributes[attribute].inline_value[0] ==
                       (c->overflow ? 1024 : 0.25f));
            assert(![frozen getSourceUniforms:&proof
                              attributeBuffer:frozen.attributes
                                        first:3
                                        count:1
                                     commands:commands]);
            Token t[4];
            unsigned n = 0;
            t[n] = token(NV2AMetalMACMov, 0, 96);
            source(&t[n], 0, 2, 0, 0xe4);
            destination(&t[n++], 0x100, 15, 0, 0, 0, 0);
            if (c->scaled) {
                t[n] = token(NV2AMetalMACMul, 0, 100);
                t[n].word[1] |= attribute << 9;
                source(&t[n], 0, 2, 0, 0);
                source(&t[n], 1, 3, 0, 0);
                destination(&t[n++], 0, 0, 0, 2, 8, 0);
            }
            t[n] = token(NV2AMetalMACArl, 0, 96);
            t[n].word[1] |= attribute << 9;
            source(&t[n], 0, c->scaled ? 1 : 2, c->scaled ? 2 : 0,
                   0x55 * c->lane);
            destination(&t[n++], 0, 0, 0, 0, 0, 0);
            t[n] = token(NV2AMetalMACMov, 0, c->base);
            source(&t[n], 0, 3, 0, 0xe4);
            destination(&t[n], 0x103, 15, 0, 0, 0, 0);
            t[n++].word[3] |= 3;
            NV2AMetalValidatedProgram *validated =
                [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                           length:n
                                                            error:&error];
            require(validated != nil, error);
            NV2AMetalProgramUniforms u = uniforms();
            u.constants[100][0] = c->scale ? c->scale : 0.25f;
            assert(![validated hasFaultFreeReadOnlyAccess:c->access
                                                constants:&u.constants[0][0]]);
            NV2AMetalWritableEncoding *candidate =
                [program encodeProgram:validated
                              uniforms:&u
                       attributeBuffer:frozen.attributes
                                 first:1
                                 count:1
                                access:c->access
                           writeEnable:NO
                             rasterize:YES
                      compactRegisters:YES
                        attributeFetch:frozen
                              commands:commands
                                 error:&error];
            NV2AMetalWritableEncoding *reference =
                [program encodeProgram:validated
                              uniforms:&u
                       attributeBuffer:frozen.attributes
                                 first:1
                                 count:1
                                access:c->access
                           writeEnable:NO
                             rasterize:YES
                      compactRegisters:NO
                              commands:commands
                                 error:&error];
            require(candidate && reference, error);
            assert(
                [candidate canUsePendingReadOnlyResultForCommands:commands] ==
                c->pending);
            admitted += c->pending;
            NV2AMetalWritableEncoding *changed = nil;
            if (c->scaled) {
                u.constants[100][0] = 400;
                changed = [program encodeProgram:validated
                                        uniforms:&u
                                 attributeBuffer:frozen.attributes
                                           first:1
                                           count:1
                                          access:c->access
                                     writeEnable:NO
                                       rasterize:YES
                                compactRegisters:YES
                                  attributeFetch:frozen
                                        commands:commands
                                           error:&error];
                require(changed != nil, error);
                assert(
                    ![changed canUsePendingReadOnlyResultForCommands:commands]);
            }
            if (!i) {
                NV2AMetalProgramInput input = { 0 };
                input.attributes[0][3] = 1;
                id<MTLBuffer> foreign = [commands.device
                    newBufferWithBytes:&input
                                length:sizeof(input)
                               options:MTLResourceStorageModeShared];
                require(foreign != nil, error);
                NV2AMetalWritableEncoding *wrong =
                    [program encodeProgram:validated
                                  uniforms:&u
                           attributeBuffer:foreign
                                     first:0
                                     count:1
                                    access:c->access
                               writeEnable:NO
                                 rasterize:YES
                          compactRegisters:YES
                            attributeFetch:frozen
                                  commands:commands
                                     error:&error];
                require(wrong != nil, error);
                assert(
                    ![wrong canUsePendingReadOnlyResultForCommands:commands]);
                NV2AMetalCommands *peer =
                    [[NV2AMetalCommands alloc] initWithDevice:commands.device
                                                        error:&error];
                require(peer && [peer beginWithError:&error], error);
                assert(![frozen getSourceUniforms:&proof
                                  attributeBuffer:frozen.attributes
                                            first:1
                                            count:1
                                         commands:peer]);
                [peer cancel];
            }
            require([commands submitWithError:&error] &&
                        [commands waitUntilIdleWithError:&error],
                    error);
            NV2AMetalWritableResult *a = [candidate resolveWithError:NULL];
            NV2AMetalWritableResult *b = [reference resolveWithError:NULL];
            assert(!!a == c->valid && !!b == c->valid);
            if (a) {
                assert(!memcmp(a.vertices.contents, b.vertices.contents,
                               sizeof(NV2AMetalVertex)));
                assert([a.constants isEqual:b.constants]);
            }
            if (changed)
                assert(![changed resolveWithError:NULL]);
            uint32_t fetchFault;
            memcpy(&fetchFault,
                   (const char *)frozen.faults.contents +
                       frozen.faultSummaryOffset,
                   sizeof(fetchFault));
            assert(fetchFault == (c->overflow ? UINT32_MAX : 0));
            faults += !c->valid;
            require([commands beginWithError:&error] != nil, error);
            assert(![frozen getSourceUniforms:&proof
                              attributeBuffer:frozen.attributes
                                        first:1
                                        count:1
                                     commands:commands]);
            assert(
                ![candidate canUsePendingReadOnlyResultForCommands:commands]);
            [commands cancel];
        }
    }
    printf(
        "Fetched readonly proof: %zu GPU cases, %u admissions, %u faults; "
        "compact/full agreement, immutable formats/constants, CMP stride-zero, "
        "overflow and buffer/range/queue/recording guards PASS\n",
        caseCount, admitted, faults);
}

static void reciprocal_readonly_tests(NV2AMetalCommands *commands,
                                      NV2AMetalWritableProgram *program,
                                      id<MTLBuffer> attributes)
{
    static const struct {
        unsigned opcode, base, access;
        uint32_t bits;
        BOOL pending, valid;
    } cases[] = {
        { NV2AMetalILURcp, 96, 0, 0x3f800000, YES, YES },
        { NV2AMetalILURcp, 191, 0, 0x3f800000, NO, NO },
        { NV2AMetalILURcp, 191, 0, 0x40000000, NO, YES },
        { NV2AMetalILURcp, 97, 0, 0xc0000000, YES, YES },
        { NV2AMetalILURcp, 96, 0, 0xc0000000, NO, NO },
        { NV2AMetalILURcp, 96, 1, 0xc0000000, YES, YES },
        { NV2AMetalILURcp, 96, 0, 0x3f000000, YES, YES },
        { NV2AMetalILURcp, 96, 0, 0, NO, NO },
        { NV2AMetalILURcc, 96, 0, 0x43800000, YES, YES },
        { NV2AMetalILURcc, 97, 0, 0xc3800000, YES, YES },
        { NV2AMetalILURcc, 96, 0, 0x3f000000, YES, YES },
        { NV2AMetalILURcc, 96, 0, 0x80000000, NO, NO },
        { NV2AMetalILURsq, 96, 0, 0xbf800000, YES, YES },
        { NV2AMetalILURsq, 96, 0, 0xc3800000, YES, YES },
        { NV2AMetalILURsq, 191, 0, 0xc3800000, NO, YES },
        { NV2AMetalILURsq, 96, 0, 0x7fc12345, NO, NO },
    };
    unsigned admitted = 0, faults = 0;
    for (unsigned i = 0; i < sizeof(cases) / sizeof(*cases); i++) {
        @autoreleasepool {
            const unsigned access = cases[i].access;
            Token t[] = { token(NV2AMetalMACMov, 0, 96),
                          token(0, cases[i].opcode, 100),
                          token(NV2AMetalMACArl, 0, 96),
                          token(NV2AMetalMACMov, 0, cases[i].base) };
            source(&t[0], 0, 2, 0, 0xe4);
            destination(&t[0], 0x100, 15, 0, 0, 0, 0);
            source(&t[1], 2, 3, 0, 0);
            destination(&t[1], 0, 0, 0, 2, 0, 15);
            source(&t[2], 0, 1, 2, 0);
            source(&t[3], 0, 3, 0, 0xe4);
            destination(&t[3], 0x103, 15, 0, 0, 0, 0);
            t[3].word[3] |= 3;
            NSError *error = nil;
            NV2AMetalValidatedProgram *validated =
                [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                           length:4
                                                            error:&error];
            require(validated != nil, error);
            NV2AMetalProgramUniforms u = uniforms();
            memcpy(&u.constants[100][0], &cases[i].bits, sizeof(float));
            assert(![validated hasFaultFreeReadOnlyAccess:access]);
            assert([validated hasFaultFreeReadOnlyAccess:access
                                               constants:&u.constants[0][0]] ==
                   cases[i].pending);
            require([commands beginWithError:&error] != nil, error);
            NV2AMetalWritableEncoding *encodings[2];
            for (unsigned compact = 0; compact < 2; compact++) {
                encodings[compact] = [program encodeProgram:validated
                                                   uniforms:&u
                                            attributeBuffer:attributes
                                                      first:0
                                                      count:4
                                                     access:access
                                                writeEnable:NO
                                                  rasterize:YES
                                           compactRegisters:compact
                                                   commands:commands
                                                      error:&error];
                require(encodings[compact] != nil, error);
            }
            assert([encodings[1]
                       canUsePendingReadOnlyResultForCommands:commands] ==
                   cases[i].pending);
            require([commands submitWithError:&error] &&
                        [commands waitUntilIdleWithError:&error],
                    error);
            NV2AMetalWritableResult *a = [encodings[0] resolveWithError:NULL];
            NV2AMetalWritableResult *b = [encodings[1] resolveWithError:NULL];
            assert(!!a == cases[i].valid && !!b == cases[i].valid);
            if (a)
                assert(!memcmp(a.vertices.contents, b.vertices.contents,
                               4 * sizeof(NV2AMetalVertex)));
            admitted += cases[i].pending;
            faults += !cases[i].valid;
        }
    }
    assert(admitted == 9 && faults == 5);
    puts("Reciprocal readonly proof: 16 GPU cases, 9 queued and 5 faults; "
         "RCP/RCC/RSQ, sign, zero/NaN, USER/FULL and compact/full agreement "
         "PASS");
}

static void fractional_reciprocal_tests(NV2AMetalCommands *commands,
                                       NV2AMetalWritableProgram *program,
                                       id<MTLBuffer> attributes)
{
    static const struct {
        unsigned opcode, base, access;
        uint32_t bits;
        float scale;
        BOOL pending, valid;
    } cases[] = {
        { NV2AMetalILURcp, 96, 0, 0x3f000000, 1, YES, YES },
        { NV2AMetalILURcp, 98, 0, 0xbf000000, 1, YES, YES },
        { NV2AMetalILURcp, 190, 0, 0x3f000000, 1, NO, NO },
        { NV2AMetalILURcp, 189, 0, 0x3f000000, 1, YES, YES },
        { NV2AMetalILURcp, 189, 0, 0x3effffff, 1, NO, YES },
        { NV2AMetalILURcp, 189, 0, 0x3f000001, 1, YES, YES },
        { NV2AMetalILURcp, 96, 0, 0x3c800000, 1, YES, YES },
        { NV2AMetalILURcp, 96, 0, 0x3c7fffff, 1, NO, YES },
        { NV2AMetalILURcp, 0, 1, 0x3c000000, 1, YES, YES },
        { NV2AMetalILURcp, 0, 0, 0x3c000000, 1, NO, YES },
        { NV2AMetalILURcp, 96, 0, 0x3b800000, .25f, YES, YES },
        { NV2AMetalILURcp, 96, 0, 0x3b7fffff, .25f, NO, YES },
        { NV2AMetalILURcp, 0, 1, 0x3b000000, .25f, YES, YES },
        { NV2AMetalILURcp, 96, 0, 0, 1, NO, NO },
        { NV2AMetalILURcp, 96, 0, 0x80000000, 1, NO, NO },
        { NV2AMetalILURcp, 96, 0, 1, 1, NO, NO },
        { NV2AMetalILURcp, 96, 0, 0x7f800000, 1, NO, YES },
        { NV2AMetalILURcp, 96, 0, 0x7fc12345, 1, NO, NO },
        { NV2AMetalILURcc, 96, 0, 0x3f000000, 1, YES, YES },
        { NV2AMetalILURcc, 98, 0, 0xbf000000, 1, YES, YES },
        { NV2AMetalILURcc, 96, 0, 0x3b800000, .25f, YES, YES },
        { NV2AMetalILURcc, 96, 0, 0x3b7fffff, .25f, NO, YES },
        { NV2AMetalILURcc, 96, 0, 0, 1, NO, NO },
        { NV2AMetalILURcc, 96, 0, 0x7f800000, 1, NO, YES },
        { NV2AMetalILURsq, 96, 0, 0x3e800000, 1, YES, YES },
        { NV2AMetalILURsq, 96, 0, 0xbe800000, 1, YES, YES },
        { NV2AMetalILURsq, 190, 0, 0x3e800000, 1, NO, NO },
        { NV2AMetalILURsq, 96, 0, 0x39800000, 1, YES, YES },
        { NV2AMetalILURsq, 96, 0, 0x37800000, .25f, YES, YES },
        { NV2AMetalILURsq, 96, 0, 0x377fffff, .25f, NO, YES },
        { NV2AMetalILURsq, 96, 0, 0, 1, NO, NO },
        { NV2AMetalILURsq, 96, 0, 0x7fc12345, 1, NO, NO },
        { NV2AMetalILURcp, 160, 0, 0x3b800000, -.25f, YES, YES },
        { NV2AMetalILURcp, 160, 0, 0xbb800000, .25f, YES, YES },
        { NV2AMetalILURcp, 165, 0, 0x3b800000, .1f, YES, YES },
        { NV2AMetalILURcp, 166, 0, 0x3b800000, .1f, NO, YES },
        { NV2AMetalILURcp, 166, 0, 0x3b800000, .1015625f, NO, NO },
        { NV2AMetalILURcp, 105, 0, 0x3b800000, 1.f / 3, YES, YES },
        { NV2AMetalILURcp, 106, 0, 0x3b800000, 1.f / 3, NO, YES },
        { NV2AMetalILURcp, 190, 0, 0x3b800000, 0x1p-126f, YES, YES },
        { NV2AMetalILURcp, 96, 0, 0x7fc12345, 0x1p-149f, YES, YES },
        { NV2AMetalILURcp, 96, 0, 0, -0x1p-149f, YES, YES },
        { NV2AMetalILURsq, 160, 0, 0x37800000, -.25f, YES, YES },
        { NV2AMetalILURsq, 165, 0, 0x37800000, .1f, YES, YES },
        { NV2AMetalILURcp, 96, 0, 0x3a000000, .03125f, YES, YES },
        { NV2AMetalILURcp, 160, 0, 0xba000000, .03125f, YES, YES },
        { NV2AMetalILURcc, 96, 0, 0x3a000000, .03125f, YES, YES },
        { NV2AMetalILURsq, 96, 0, 0x34800000, .03125f, YES, YES },
        { NV2AMetalILURsq, 96, 0, 0xb4800000, .03125f, YES, YES },
        { NV2AMetalILURcp, 96, 0, 0x39ffffff, .03125f, NO, YES },
        { NV2AMetalILURsq, 96, 0, 0x347fffff, .03125f, NO, YES },
        { NV2AMetalILURcp, 96, 0, 0x39800000, .015625f, YES, YES },
        { NV2AMetalILURcp, 96, 0, 0x33800000, 0x1p-18f, YES, YES },
        { NV2AMetalILURcp, 160, 0, 0xb3800000, 0x1p-18f, YES, YES },
        { NV2AMetalILURcc, 96, 0, 0x33800000, 0x1p-18f, YES, YES },
        { NV2AMetalILURsq, 96, 0, 0x27800000, 0x1p-18f, YES, YES },
        { NV2AMetalILURsq, 96, 0, 0xa7800000, 0x1p-18f, YES, YES },
        { NV2AMetalILURcp, 96, 0, 0x337fffff, 0x1p-18f, NO, YES },
        { NV2AMetalILURsq, 96, 0, 0x277fffff, 0x1p-18f, NO, YES },
    };
    unsigned admitted = 0, faults = 0;
    NSError *error = nil;
    for (unsigned i = 0; i < sizeof(cases) / sizeof(*cases); i++) {
        @autoreleasepool {
            Token t[] = { token(NV2AMetalMACMov, 0, 96),
                          token(NV2AMetalMACMov, 0, 100),
                          token(0, cases[i].opcode, 96),
                          token(NV2AMetalMACMul, 0, 101),
                          token(NV2AMetalMACArl, 0, 96),
                          token(NV2AMetalMACMov, 0, cases[i].base) };
            source(&t[0], 0, 2, 0, 0xe4);
            destination(&t[0], 0x100, 15, 0, 0, 0, 0);
            source(&t[1], 0, 3, 0, 0xaa);
            destination(&t[1], 0, 0, 0, 3, 15, 0);
            source(&t[2], 2, 1, 3, 0x55);
            t[2].word[2] |= 1u << 10; /* Negated C, after MOV/swizzle. */
            destination(&t[2], 0, 0, 0, 2, 0, 15);
            source(&t[3], 0, 1, 2, 0x55);
            source(&t[3], 1, 3, 0, 0);
            destination(&t[3], 0, 0, 0, 4, 15, 0);
            source(&t[4], 0, 1, 4, 0);
            source(&t[5], 0, 3, 0, 0xe4);
            destination(&t[5], 0x103, 15, 0, 0, 0, 0);
            t[5].word[3] |= 3;
            NV2AMetalValidatedProgram *validated =
                [[NV2AMetalValidatedProgram alloc] initWithTokens:t[0].word
                                                           length:6 error:&error];
            require(validated != nil, error);
            NV2AMetalProgramUniforms u = uniforms();
            uint32_t negated = cases[i].bits ^ 0x80000000u;
            memcpy(&u.constants[100][2], &negated, 4);
            u.constants[101][0] = cases[i].scale;
            BOOL pending = [validated hasFaultFreeReadOnlyAccess:cases[i].access
                constants:u.constants[0]];
            if (pending != cases[i].pending) {
                fprintf(stderr, "Fractional reciprocal case %u: pending %d expected %d\n",
                        i, pending, cases[i].pending);
                abort();
            }
            require([commands beginWithError:&error] != nil, error);
            NV2AMetalWritableEncoding *encoded[2];
            for (unsigned compact = 0; compact < 2; compact++) {
                encoded[compact] = [program encodeProgram:validated uniforms:&u
                    attributeBuffer:attributes first:0 count:4 access:cases[i].access
                    writeEnable:NO rasterize:YES compactRegisters:compact
                    commands:commands error:&error];
                require(encoded[compact] != nil, error);
            }
            assert([encoded[1] canUsePendingReadOnlyResultForCommands:commands] ==
                   cases[i].pending);
            require([commands submitWithError:&error] &&
                    [commands waitUntilIdleWithError:&error], error);
            NV2AMetalWritableResult *a = [encoded[0] resolveWithError:NULL];
            NV2AMetalWritableResult *b = [encoded[1] resolveWithError:NULL];
            if (!!a != cases[i].valid || !!b != cases[i].valid) {
                fprintf(stderr, "Fractional reciprocal case %u: valid %d/%d expected %d\n",
                        i, !!a, !!b, cases[i].valid);
                abort();
            }
            if (a) {
                assert(!memcmp(a.vertices.contents, b.vertices.contents,
                               4 * sizeof(NV2AMetalVertex)));
                assert(!memcmp(a.constants.bytes, u.constants, sizeof(u.constants)) &&
                       !memcmp(b.constants.bytes, u.constants, sizeof(u.constants)));
            }
            admitted += cases[i].pending;
            faults += !cases[i].valid;
        }
    }
    assert(admitted == 35 && faults == 10);
    puts("Fractional reciprocal proof:59 GPU cases,35 queued,10 faults;"
         "RCP/RCC/RSQ,binade boundaries,MOV/negation/swizzle/scaling,USER/FULL,"
         "signed zero/NaN/Inf/subnormal and exact compact/full outputs PASS");
}

static void fault_free_readonly_tests(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    /* Keep this an interpreter proof, independent of the specialization/JIT
     * thresholds and of the new host metadata being checked. */
    NV2AMetalWritableProgram *program =
        [[SpecializedReadonlyReference alloc] initWithDevice:commands.device
                                                       error:&error];
    require(program != nil, error);
    NV2AMetalProgramInput values[4];
    const uint32_t inputs[] = { 0x3f000000, 0x7fc12345, 0x7f800000,
                                0x4f000000 };
    for (unsigned v = 0; v < 4; v++) {
        writable_input(&values[v], v);
        memcpy(&values[v].attributes[0][0], &inputs[v], 4);
    }
    id<MTLBuffer> attributes =
        [commands.device newBufferWithBytes:values
                                     length:sizeof(values)
                                    options:MTLResourceStorageModeShared];
    assert(attributes);
    /* Operand use from the existing instruction ISA: A, AB, AC, ABC. ILU
     * independently consumes C. Destination masks never disable operand reads.
     */
    static const unsigned operands[] = { 0, 1, 3, 5, 7, 3, 3,
                                         3, 3, 3, 3, 3, 3, 1 };
    const unsigned rows[] = { 0, 57, 58, 59, 60, 95, 96, 191 };
    NSMutableArray *encodings = [NSMutableArray new],
                   *programs = [NSMutableArray new],
                   *accesses = [NSMutableArray new],
                   *expected = [NSMutableArray new];
    proof_cases = proof_safe = proof_captured = proof_faults = 0;
    for (unsigned mac = 0; mac <= 13; mac++)
        for (unsigned ilu = 0; ilu <= 7; ilu++)
            for (unsigned sourceIndex = 0; sourceIndex < 3; sourceIndex++)
                for (unsigned rowIndex = 0; rowIndex < 8; rowIndex++)
                    for (unsigned relative = 0; relative < 2; relative++)
                        for (unsigned masked = 0; masked < 2; masked++)
                            for (unsigned access = 0; access < 2; access++) {
                                @autoreleasepool {
                                    unsigned row = rows[rowIndex];
                                    Token t = token(mac, ilu, row);
                                    for (unsigned s = 0; s < 3; s++)
                                        source(&t, s, s == sourceIndex ? 3 : 2,
                                               0, 0xe4);
                                    destination(
                                        &t, 0x103,
                                        masked || (mac == 13 && !ilu) ? 0 : 15,
                                        ilu != 0, 0, 0, 0);
                                    t.word[3] |= 1u | relative << 1;
                                    NV2AMetalValidatedProgram *validated =
                                        [[NV2AMetalValidatedProgram alloc]
                                            initWithTokens:t.word
                                                    length:1
                                                     error:&error];
                                    require(validated != nil, error);
                                    assert(![validated
                                        hasFaultFreeReadOnlyAccess:2]);
                                    unsigned reads =
                                        operands[mac] | (ilu ? 4 : 0);
                                    assert(validated.readAttributes ==
                                           !!(reads & ~(1u << sourceIndex)));
                                    BOOL needed = reads & (1u << sourceIndex);
                                    BOOL safe =
                                        mac != 13 &&
                                        (!needed || access || row >= 96 ||
                                         (!relative &&
                                          (row == 58 || row == 59)));
                                    /* This fixture's rows divisible by four
                                     * contain literal 0.5f. A direct ARL from
                                     * their X lane is bounded even though the
                                     * constants-independent proof rejects it.
                                     * Keep that original static expectation. */
                                    BOOL pendingSafe =
                                        safe ||
                                        (mac == 13 && sourceIndex == 0 &&
                                         row % 4 == 0 && (access || row >= 96));
                                    if (!encodings.count)
                                        require(
                                            [commands beginWithError:&error] !=
                                                nil,
                                            error);
                                    NV2AMetalProgramUniforms u = uniforms();
                                    for (unsigned r = 0; r < 192; r++)
                                        memcpy(&u.constants[r][0],
                                               &inputs[r % 4], 4);
                                    NV2AMetalWritableEncoding *encoded =
                                        [program encodeProgram:validated
                                                      uniforms:&u
                                               attributeBuffer:attributes
                                                         first:0
                                                         count:4
                                                        access:access
                                                   writeEnable:NO
                                                     rasterize:YES
                                              compactRegisters:YES
                                                      commands:commands
                                                         error:&error];
                                    require(encoded != nil, error);
                                    NSError *pendingError = nil;
                                    NV2AMetalWritableResult *pending = [encoded
                                        pendingReadOnlyResultForCommands:
                                            commands
                                                                   error:
                                                                       &
                                                                       pendingError];
                                    assert(pendingSafe ?
                                               (pending && !pendingError) :
                                               (!pending && pendingError));
                                    if (pending) {
                                        assert(!memcmp(pending.constants.bytes,
                                                       u.constants,
                                                       sizeof(u.constants)));
                                        assert(!pending.registers &&
                                               pending.vertices &&
                                               pending.vertexCount == 4);
                                    }
                                    [encodings addObject:encoded];
                                    [programs addObject:validated];
                                    [accesses addObject:@(access)];
                                    [expected
                                        addObject:@((safe ? 1u : 0u) |
                                                    (pendingSafe ? 2u : 0u))];
                                    if (encodings.count == 64) {
                                        proof_finish(commands, encodings,
                                                     programs, accesses,
                                                     expected);
                                        [encodings removeAllObjects];
                                        [programs removeAllObjects];
                                        [accesses removeAllObjects];
                                        [expected removeAllObjects];
                                    }
                                }
                            }
    if (encodings.count)
        proof_finish(commands, encodings, programs, accesses, expected);
    /* A proof does not authorize another queue, a discarded recording or
     * a real constant-writing serial context. */
    Token t = token(1, 0, 96);
    source(&t, 0, 3, 0, 0xe4);
    destination(&t, 0x103, 15, 0, 0, 0, 0);
    t.word[3] |= 3;
    NV2AMetalValidatedProgram *safe =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:t.word
                                                   length:1
                                                    error:&error];
    assert([safe hasFaultFreeReadOnlyAccess:0] &&
           [safe hasFaultFreeReadOnlyAccess:1]);
    NV2AMetalProgramUniforms u = uniforms();
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalWritableEncoding *live = [program encodeProgram:safe
                                                    uniforms:&u
                                             attributeBuffer:attributes
                                                       first:0
                                                       count:4
                                                      access:0
                                                 writeEnable:NO
                                                   rasterize:YES
                                            compactRegisters:YES
                                                    commands:commands
                                                       error:&error];
    require(live != nil, error);
    NV2AMetalCommands *foreign =
        [[NV2AMetalCommands alloc] initWithDevice:commands.device error:&error];
    require(foreign != nil, error);
    assert(![live pendingReadOnlyResultForCommands:foreign error:&error]);
    [commands cancel];
    assert(![live pendingReadOnlyResultForCommands:commands error:&error]);
    require([commands beginWithError:&error] != nil, error);
    assert(![live pendingReadOnlyResultForCommands:commands error:&error]);
    [commands cancel];
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalWritableEncoding *raw = [program encodeProgram:safe uniforms:&u
        attributeBuffer:attributes first:0 count:4 access:0 writeEnable:NO
        rasterize:NO compactRegisters:YES commands:commands error:&error];
    require(raw != nil, error);
    NV2AMetalWritableResult *pendingRaw =
        [raw pendingReadOnlyResultForCommands:commands error:&error];
    require(pendingRaw != nil, error);
    assert(!pendingRaw.vertices && !pendingRaw.registers && pendingRaw.vertexCount == 4 &&
           !memcmp(pendingRaw.constants.bytes, u.constants, sizeof(u.constants)));
    require([commands submitWithError:&error] && [commands waitUntilIdleWithError:&error], error);
    NV2AMetalWritableResult *completedRaw = [raw resolveWithError:&error];
    require(completedRaw != nil, error);
    assert([pendingRaw.constants isEqual:completedRaw.constants] &&
           [pendingRaw.written isEqual:completedRaw.written] && !completedRaw.vertices);
    destination(&t, 191, 15, 0, 0, 0, 0);
    t.word[3] |= 1;
    NV2AMetalValidatedProgram *writer =
        [[NV2AMetalValidatedProgram alloc] initWithTokens:t.word
                                                   length:1
                                                    error:&error];
    assert(writer.mayWriteConstants && [writer hasFaultFreeReadOnlyAccess:1]);
    require([commands beginWithError:&error] != nil, error);
    NV2AMetalWritableEncoding *write = [program encodeProgram:writer
                                                     uniforms:&u
                                              attributeBuffer:attributes
                                                        first:0
                                                        count:4
                                                       access:1
                                                  writeEnable:YES
                                                    rasterize:YES
                                             compactRegisters:YES
                                                     commands:commands
                                                        error:&error];
    require(write != nil, error);
    assert(![write pendingReadOnlyResultForCommands:commands error:&error]);
    require([commands submitWithError:&error] &&
                [commands waitUntilIdleWithError:&error],
            error);
    NV2AMetalWritableResult *written = [write resolveWithError:&error];
    require(written != nil, error);
    assert(((const uint32_t *)written.written.bytes)[191] == 1);
    assert(proof_cases == 14 * 8 * 3 * 8 * 2 * 2 * 2 && proof_safe &&
           proof_captured == 128 && proof_faults);
    printf(
        "Readonly fault proof:%u native interpreter cases/%u static/%u "
        "captured "
        "proven/%u GPU "
        "faults; "
        "all MAC/ILU/operands,USER/FULL,58/59 aperture,relative/ARL,zero masks,"
        "NaN/Inf/address overflow; known context and "
        "foreign/cancel/reuse/writer guards PASS\n",
        proof_cases, proof_safe, proof_captured, proof_faults);
    attribute_readonly_tests(commands, program);
    reciprocal_readonly_tests(commands, program, attributes);
    fractional_reciprocal_tests(commands, program, attributes);
}
#endif
