/* Exact strided VRAM read ownership, independent of vertex decoding.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_STRIDED_READS_H
#define TEST_METAL_STRIDED_READS_H

static BOOL strided_oracle(NV2AMetalVRAMReadPattern p, NSUInteger address,
                           NSUInteger length)
{
    for (NSUInteger byte = address; byte < address + length; byte++)
        for (NSUInteger cell = p.address; cell < p.address + p.length;
             cell += p.stride)
            if (byte >= cell && byte - cell < p.element)
                return YES;
    return NO;
}

static void strided_ready(NV2AMetalSurfaceCache *cache, NSUInteger address,
                          NSUInteger length, BOOL expected)
{
    NSError *error = nil;
    BOOL ready = !expected;
    require([cache tryIdleCPUAccessAtAddress:address
                                      length:length
                                       write:YES
                                   completed:&ready
                                       error:&error],
            error);
    assert(ready == expected);
}

static void strided_read_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    NV2AMetalCommands *producer =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    id<MTLBuffer> vram =
        [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:vram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(commands && producer && vram && cache, error);
    unsigned cases = 0, probes = 0;
    for (unsigned independent = 0; independent < 2; independent++)
        for (NSUInteger stride = 1; stride <= 12; stride++)
            for (NSUInteger element = 1; element <= stride; element++) {
                NV2AMetalVRAMReadPattern p = { 4093,
                                               (element % 5) * stride + element,
                                               stride, element };
                NV2AMetalIndependentReads *reader = nil;
                if (independent) {
                    require([cache tryBeginIndependentReadPatterns:&p
                                                             count:1
                                                          commands:producer
                                                             reads:&reader
                                                             error:&error],
                            error);
                    assert(reader);
                } else
                    require([cache prepareGPUReadPattern:p error:&error],
                            error);
                /* Compare every byte and crossings against a deliberately
                 * enumerating oracle, including half-open and zero lengths. */
                for (NSUInteger address = p.address - 2;
                     address <= p.address + p.length + 2; address++)
                    for (NSUInteger length = 0; length <= 4; length++) {
                        strided_ready(cache, address, length,
                                      !strided_oracle(p, address, length));
                        probes++;
                    }
                if (independent)
                    [cache cancelIndependentReads:reader];
                else
                    [cache cancel];
                strided_ready(cache, p.address, p.length, YES);
                assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard,
                                                 p.address, p.length, YES));
                cases++;
            }

    /* 16,384 cells use one record, not a per-vertex interval list. */
    NV2AMetalVRAMReadPattern large = { 0, 65533, 4, 1 };
    for (unsigned independent = 0; independent < 2; independent++) {
        NV2AMetalIndependentReads *reader = nil;
        if (independent) {
            require([cache tryBeginIndependentReadPatterns:&large
                                                     count:1
                                                  commands:producer
                                                     reads:&reader
                                                     error:&error],
                    error);
            assert(reader &&
                   [[reader valueForKey:@"spans"] length] == sizeof(large));
        } else {
            require([cache prepareGPUReadPattern:large error:&error], error);
            assert([[cache valueForKey:@"pendingReads"] length] ==
                   sizeof(large));
        }
        strided_ready(cache, 65532, 1, NO);
        strided_ready(cache, 65533, 3, YES);
        strided_ready(cache, 4093, 3, YES);
        strided_ready(cache, 4095, 2, NO);
        if (independent)
            [cache cancelIndependentReads:reader];
        else
            [cache cancel];
        assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 0, 65536, YES));
        cases++;
    }

    NV2AMetalVRAMReadPattern p = { 4093, 5 * 64 + 3, 64, 3 };
    /* A pending writer in padding must not prevent a separate producer.
     * Crossing either end of a payload must still request the ordered queue. */
    for (NSUInteger address = p.address - 1; address < p.address + p.length + 1;
         address++) {
        require([cache prepareGPUWriteAtAddress:address length:2 error:&error],
                error);
        NV2AMetalIndependentReads *reader = nil;
        require([cache tryBeginIndependentReadPatterns:&p
                                                 count:1
                                              commands:producer
                                                 reads:&reader
                                                 error:&error],
                error);
        assert((reader != nil) == !strided_oracle(p, address, 2));
        if (reader)
            [cache cancelIndependentReads:reader];
        [cache cancel];
        cases++;
    }

    /* Accepted read ownership survives cancellation of a later suffix. */
    require([cache prepareGPUReadPattern:p error:&error] &&
                [cache checkpointWithError:&error],
            error);
    NV2AMetalVRAMReadPattern suffix = { 8192, 33, 32, 1 };
    require([cache prepareGPUReadPattern:suffix error:&error], error);
    [cache cancel];
    strided_ready(cache, p.address, 1, NO);
    strided_ready(cache, p.address + p.element, p.stride - p.element, YES);
    strided_ready(cache, suffix.address, suffix.length, YES);
    require([cache submitWithError:&error] &&
                [cache waitUntilIdleWithError:&error],
            error);
    strided_ready(cache, p.address, p.length, YES);
    for (unsigned cancel = 0; cancel < 2; cancel++) {
        NV2AMetalIndependentReads *reader = nil;
        require([cache tryBeginIndependentReadPatterns:&p
                                                 count:1
                                              commands:producer
                                                 reads:&reader
                                                 error:&error],
                error);
        require(reader && [cache submitIndependentReads:reader error:&error],
                error);
        if (cancel)
            [cache cancelIndependentReads:reader];
        strided_ready(cache, p.address, 1, NO);
        strided_ready(cache, p.address + p.element, p.stride - p.element, YES);
        require([cache completeIndependentReads:reader error:&error], error);
        strided_ready(cache, p.address, p.length, YES);
    }

    NV2AMetalVRAMReadPattern invalid[] = { { 0, 1, 0, 1 },
                                           { 0, 1, 4, 0 },
                                           { 0, 1, 4, 2 },
                                           { 0, 4, 2, 3 },
                                           { 0, 8, 4, 1 },
                                           { 65535, 2, 1, 1 },
                                           { NSUIntegerMax, 2, 1, 1 },
                                           { 65536, 0, 1, 1 } };
    for (NSUInteger i = 0; i < sizeof(invalid) / sizeof(*invalid); i++) {
        error = nil;
        assert(![cache prepareGPUReadPattern:invalid[i] error:&error] && error);
        error = nil;
        NV2AMetalIndependentReads *reader = nil;
        assert(![cache tryBeginIndependentReadPatterns:&invalid[i]
                                                 count:1
                                              commands:producer
                                                 reads:&reader
                                                 error:&error] &&
               error && !reader);
        assert(!commands.commandBuffer && !producer.commandBuffer);
    }
    error = nil;
    /* Exact end of VRAM and a one-cell strided range are legal. */
    NV2AMetalVRAMReadPattern end = { 65535, 1, 64, 1 };
    require([cache prepareGPUReadPattern:end error:&error], error);
    strided_ready(cache, 65535, 1, NO);
    [cache cancel];
    assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 65535, 1, YES));
    printf("Strided read ownership:%u patterns/writers,%u exact byte probes;"
           "checkpoint/cancel/submit/retirement,range rejection PASS\n",
           cases, probes);
    checks++;
}
#endif
