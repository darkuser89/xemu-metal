/* Cross-descriptor readonly index metadata through real Begin/End captures.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_READONLY_INDEX_PLAN_REUSE_PGRAPH_H
#define TEST_METAL_READONLY_INDEX_PLAN_REUSE_PGRAPH_H

typedef struct ReadonlyIndexReuseWork {
    BOOL reference;
    NSUInteger requests, probes, hits, builds;
    NSUInteger payload, keyLength, firstRead, rangePrefix, readonlyPrefix;
    NSUInteger inputCount, readonlyCount;
    BOOL sequenceMatches;
    __unsafe_unretained NSMutableArray *inputs;
    __unsafe_unretained NSMutableArray *views;
} ReadonlyIndexReuseWork;
static _Thread_local ReadonlyIndexReuseWork *irp_work;
static BOOL (*irp_reuse_original)(id, SEL, id, NSUInteger);
static id (*irp_indices_original)(id, SEL, id, NSUInteger, NSData **,
                                  NSUInteger *);
static id (*irp_builder_original)(id, SEL, id, NSUInteger, NSData **,
                                  NSUInteger *, BOOL *);
static BOOL irp_reuse(id owner, SEL selector, id input, NSUInteger prefix)
{
    if (irp_work) {
        irp_work->probes++;
        if (irp_work->reference)
            return NO; /* Only the new cross-descriptor route is disabled. */
    }
    BOOL hit = irp_reuse_original(owner, selector, input, prefix);
    if (irp_work)
        irp_work->hits += hit;
    return hit;
}
static id irp_indices(id owner, SEL selector, NV2AMetalPendingInput *input,
                      NSUInteger prefix, NSData **remap, NSUInteger *current)
{
    if (irp_work) {
        irp_work->requests++;
        [irp_work->inputs addObject:input];
        [irp_work->views addObject:input.indices];
    }
    return irp_indices_original(owner, selector, input, prefix, remap, current);
}
static id irp_builder(id owner, SEL selector, id input, NSUInteger prefix,
                      NSData **remap, NSUInteger *current, BOOL *computed)
{
    if (irp_work)
        irp_work->builds++;
    return irp_builder_original(owner, selector, input, prefix, remap, current,
                                computed);
}
static NSUInteger irp_payload(void)
{
    NV2AMetalPGRAPHFetch *fetch = [draw valueForKey:@"fetch"];
    NSUInteger bytes =
        [[fetch valueForKey:@"floatProofPayload"] unsignedIntegerValue];
    for (NSString *key in @[
             @"arrayRangesKey", @"arrayRanges", @"indexRangesKey",
             @"indexRanges", @"readonlyUniqueIndices", @"readonlyRemap"
         ])
        bytes += ((NSData *)[fetch valueForKey:key]).length;
    return bytes;
}
static void irp_scene(BOOL monotone)
{
    /* Public fresh owners keep the cold phase independent of earlier CLI
     * groups and of the preceding reference run. No private cache is reset. */
    NSError *error = nil;
    qemu_mutex_lock(&state->pgraph.lock);
    require([draw closeWithError:&error], error);
    qemu_mutex_unlock(&state->pgraph.lock);
    draw = nil;
    surfaces = [[NV2AMetalPGRAPHSurfaces alloc] initWithState:state
                                                        error:&error];
    draw = [[NV2AMetalPGRAPHDraw alloc] initWithState:state
                                             surfaces:surfaces
                                                error:&error];
    require(surfaces && draw, error);
    fsm_scene(NO, 3);
    if (monotone) {
        state->pgraph.inline_elements_length = 30;
        for (unsigned i = 0; i < 30; i++)
            state->pgraph.inline_elements[i] = i;
    }
}
static BOOL irp_prepare(ReadonlyIndexReuseWork *work, FloatProofPGRAPHWork *gpu,
                        NSError **error)
{
    assert(!irp_work && !fpp_work);
    irp_work = work;
    fpp_work = gpu;
    @try {
        return [draw prepareVertexStateChangeWithError:error];
    } @finally {
        irp_work = NULL;
        fpp_work = NULL;
    }
}
static BOOL irp_end(ReadonlyIndexReuseWork *work, FloatProofPGRAPHWork *gpu,
                    NSError **error)
{
    assert(!irp_work && !fpp_work);
    irp_work = work;
    fpp_work = gpu;
    @try {
        return [draw endWithError:error];
    } @finally {
        irp_work = NULL;
        fpp_work = NULL;
    }
}
static void irp_archives(NSMutableArray *actual, NSError **error)
{
    NSData *pending = [draw pendingSnapshotWithError:error];
    NSData *begin = [draw beginSnapshotWithError:error];
    NSData *vertex = draw.vertexSnapshot;
    require(pending && begin && vertex, *error);
    [actual addObjectsFromArray:@[ pending, begin, vertex ]];
}
static void irp_raw_write(NSUInteger address, uint32_t bits)
{
    NSError *error = nil;
    NV2AMetalCommands *commands = surfaces.cache.commands;
    id<MTLBuffer> source =
        [commands.device newBufferWithBytes:&bits
                                     length:4
                                    options:MTLResourceStorageModeShared];
    require(source &&
                [surfaces.cache prepareGPUWriteAtAddress:address
                                                  length:4
                                                   error:&error] &&
                [commands addResource:source error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    require(e != nil, nil);
    [e copyFromBuffer:source
             sourceOffset:0
                 toBuffer:surfaces.cache.vram
        destinationOffset:address
                     size:4];
    [e endEncoding];
    require([surfaces.cache submitWithError:&error] &&
                [surfaces.cache waitUntilIdleWithError:&error],
            error);
    assert(!memcmp(state->vram_ptr + address, &bits, 4));
}
static void irp_repeated_pair(unsigned kind)
{
    NSArray *reference = nil;
    ReadonlyIndexReuseWork work[2][3] = { 0 };
    FloatProofPGRAPHWork gpu[2][3] = { 0 };
    ReadonlyIndexReuseWork faultWork[2] = { 0 };
    FloatProofPGRAPHWork faultGPU[2] = { 0 };
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            irp_scene(kind == 4);
            PGRAPHState *pg = &state->pgraph;
            NSError *error = nil;
            NSMutableArray *actual = [NSMutableArray new];
            __attribute__((objc_precise_lifetime)) NSMutableArray *inputs =
                [NSMutableArray new];
            __attribute__((objc_precise_lifetime)) NSMutableArray *views =
                [NSMutableArray new];
            qemu_mutex_lock(&pg->lock);
            for (unsigned pass = 0; pass < 3; pass++) {
                if (kind == 1 && pass == 1) {
                    /* Same set, different sequence and logical Current. */
                    for (unsigned i = 0; i < 6144; i++)
                        pg->inline_elements[i] = (i * 13 + 18) % 32;
                    pg->inline_elements[6143] = 4;
                }
                if (kind == 2 && pass == 1) {
                    const float zero = 0;
                    cpu_write(20480 + 7 * 4, 4);
                    memcpy(state->vram_ptr + 20480 + 7 * 4, &zero, 4);
                }
                if (kind == 2 && pass == 2)
                    irp_raw_write(24576 + 7 * 16, UINT32_C(0x3f000000));
                NSUInteger observed = inputs.count;
                work[candidate][pass] = (ReadonlyIndexReuseWork){
                    .reference = !candidate, .inputs = inputs, .views = views
                };
                require([draw beginWithError:&error], error);
                /* The ordinary caller has no intermediate XF boundary.
                 * Materializing one here would make End refresh a last-only
                 * Current range and correctly discard the full-key witness. */
                irp_archives(actual, &error);
                assert(!((NSData *)actual[actual.count - 3]).length);
                require(irp_end(&work[candidate][pass], &gpu[candidate][pass],
                                &error),
                        error);
                [actual addObject:fpp_frame(pg)];
                unsigned last = kind == 4 ? 29 : kind == 1 && pass ? 4 : 7;
                assert(!memcmp(pg->vertex_attributes[1].inline_value,
                               state->vram_ptr + 20480 + last * 4, 4));
                assert(!memcmp(pg->vertex_attributes[5].inline_value,
                               state->vram_ptr + 24576 + last * 16, 16));
                /* Retain observations only to prove unequal identities;
                 * they never enter a factory or replace a live descriptor. */
                assert(inputs.count > observed);
                if (observed) {
                    assert(inputs[observed] != inputs[0] &&
                           views[observed] != views[0]);
                }
                assert(irp_payload() <= 65536);
                NV2AMetalPGRAPHFetch *fetch = [draw valueForKey:@"fetch"];
                ReadonlyIndexReuseWork *phase = &work[candidate][pass];
                phase->payload = irp_payload();
                phase->keyLength =
                    [[fetch valueForKey:@"indexRangesKey"] length];
                phase->firstRead = [[fetch valueForKey:@"indexRangesFirstRead"]
                    unsignedIntegerValue];
                phase->rangePrefix = [[fetch valueForKey:@"indexRangesPrefix"]
                    unsignedIntegerValue];
                phase->readonlyPrefix = [[fetch
                    valueForKey:@"readonlyIndexPrefix"] unsignedIntegerValue];
                phase->readonlyCount = [[fetch
                    valueForKey:@"readonlyIndexCount"] unsignedIntegerValue];
                phase->inputCount =
                    ((NV2AMetalPendingInput *)inputs.lastObject).count;
                phase->sequenceMatches =
                    [fetch valueForKey:@"readonlyIndexSequence"] ==
                    [fetch valueForKey:@"indexRangesKey"];
            }
            if (kind == 2) {
                /* The same pure plan must not bypass a new selected NaN. */
                irp_raw_write(20480 + 5 * 4, UINT32_C(0x7fc12345));
                require([draw beginWithError:&error], error);
                NSData *host = fpp_host();
                faultWork[candidate] = (ReadonlyIndexReuseWork){
                    .reference = !candidate, .inputs = inputs, .views = views
                };
                assert(!irp_prepare(&faultWork[candidate], &faultGPU[candidate],
                                    &error) &&
                       error && [host isEqualToData:fpp_host()]);
                [actual addObjectsFromArray:@[
                    error.domain, error.localizedDescription, @(error.code)
                ]];
                error = nil;
                const float repaired = 1;
                cpu_write(20480 + 5 * 4, 4);
                memcpy(state->vram_ptr + 20480 + 5 * 4, &repaired, 4);
                require(irp_prepare(&faultWork[candidate], &faultGPU[candidate],
                                    &error),
                        error);
                irp_archives(actual, &error);
                require(irp_end(&faultWork[candidate], &faultGPU[candidate],
                                &error),
                        error);
                [actual addObject:fpp_frame(pg)];
            }
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            qemu_mutex_unlock(&pg->lock);
        }
    }
    /* Full GPU framebuffer/depth/query/Current/context and archive bytes
     * precede every claim about omitted builder work. */
    for (unsigned pass = 0; pass < 3; pass++) {
        assert(work[0][pass].builds == 1);
        BOOL miss = !pass || (kind == 1 && pass == 1);
        if (work[1][pass].builds != (NSUInteger)miss) {
            for (unsigned candidate = 0; candidate < 2; candidate++) {
                const ReadonlyIndexReuseWork *phase = &work[candidate][pass];
                fprintf(
                    stderr,
                    "Readonly PGRAPH kind%u pass%u candidate%u "
                    "expectedBuilds%u builds%lu probes%lu hits%lu "
                    "requests%lu payload%lu keyLength%lu "
                    "sequenceMatches%u firstRead%lu rangePrefix%lu "
                    "readonlyPrefix%lu inputCount%lu readonlyCount%lu\n",
                    kind, pass, candidate, candidate ? (unsigned)miss : 1u,
                    (unsigned long)phase->builds, (unsigned long)phase->probes,
                    (unsigned long)phase->hits, (unsigned long)phase->requests,
                    (unsigned long)phase->payload,
                    (unsigned long)phase->keyLength, phase->sequenceMatches,
                    (unsigned long)phase->firstRead,
                    (unsigned long)phase->rangePrefix,
                    (unsigned long)phase->readonlyPrefix,
                    (unsigned long)phase->inputCount,
                    (unsigned long)phase->readonlyCount);
            }
        }
        assert(work[1][pass].builds == (NSUInteger)miss);
        assert(work[1][pass].hits == (NSUInteger)!miss);
        assert(gpu[0][pass].records == (kind == 4 ? 30u : 32u) &&
               gpu[1][pass].records == gpu[0][pass].records);
    }
    if (kind == 2) {
        /* A failed capture did not accept its input into the journal.
         * Repair therefore creates another descriptor of the same sequence. */
        assert(faultWork[0].requests == 2 && faultWork[1].requests == 2 &&
               faultWork[0].builds == 2 && !faultWork[1].builds &&
               faultWork[1].hits == 2);
        assert(faultGPU[0].records == 64 && faultGPU[1].records == 64);
    }
}

static void irp_lifecycle_pair(void)
{
    NSArray *reference = nil;
    NSUInteger builds[2], hits[2], records[2];
    BOOL currentOnly[2];
    for (unsigned candidate = 0; candidate < 2; candidate++) {
        @autoreleasepool {
            irp_scene(NO);
            PGRAPHState *pg = &state->pgraph;
            NSError *error = nil;
            NSMutableArray *actual = [NSMutableArray new];
            __attribute__((objc_precise_lifetime)) NSMutableArray *inputs =
                [NSMutableArray new];
            __attribute__((objc_precise_lifetime)) NSMutableArray *views =
                [NSMutableArray new];
            ReadonlyIndexReuseWork work = { .reference = !candidate,
                                            .inputs = inputs,
                                            .views = views };
            FloatProofPGRAPHWork gpu = { 0 };
            qemu_mutex_lock(&pg->lock);
            require([draw beginWithError:&error] &&
                        irp_prepare(&work, &gpu, &error) &&
                        irp_end(&work, &gpu, &error),
                    error);
            [actual addObject:fpp_frame(pg)];
            NV2AMetalPGRAPHFetch *fetch = [draw valueForKey:@"fetch"];
            currentOnly[candidate] =
                [[fetch valueForKey:@"indexRangesKey"] length] == 4 &&
                [[fetch valueForKey:@"indexRangesFirstRead"]
                    unsignedIntegerValue] == 6143 &&
                [[fetch valueForKey:@"indexRangesPrefix"]
                    unsignedIntegerValue] == 6144 &&
                [[fetch valueForKey:@"readonlyIndexPrefix"]
                    unsignedIntegerValue] == 0;
            /* That real Current-only refresh cannot witness a new full
             * sequence. The next Begin is cold, and the following one warm. */
            require([draw beginWithError:&error] &&
                        irp_end(&work, &gpu, &error),
                    error);
            [actual addObject:fpp_frame(pg)];
            require([draw beginWithError:&error] &&
                        irp_end(&work, &gpu, &error),
                    error);
            [actual addObject:fpp_frame(pg)];
            pg->inline_elements_length = 3072;
            require([draw beginWithError:&error] &&
                        irp_prepare(&work, &gpu, &error),
                    error);
            NSData *prefix = [draw pendingSnapshotWithError:&error];
            require(prefix != nil, error);
            pg->inline_elements_length = 6144;
            require(irp_prepare(&work, &gpu, &error), error);
            NSData *pending = [draw pendingSnapshotWithError:&error];
            NSData *begin = [draw beginSnapshotWithError:&error];
            NSData *vertex = draw.vertexSnapshot;
            require(pending && begin && vertex &&
                        [draw flushWithError:&error] &&
                        [draw discardForRestoreWithError:&error] &&
                        [draw restoreVertexSnapshot:vertex error:&error] &&
                        [draw restoreBeginSnapshot:begin error:&error] &&
                        [draw restorePendingSnapshot:pending error:&error] &&
                        [draw beginWithError:&error],
                    error);
            NSData *restored = [draw pendingSnapshotWithError:&error];
            require(restored != nil, error);
            assert([pending isEqualToData:restored]);
            [actual addObjectsFromArray:@[
                prefix, pending, begin, vertex, restored
            ]];
            NSData *host = fpp_host();
            fpp_fail_emit = YES;
            irp_work = &work;
            fpp_work = &gpu;
            BOOL ok;
            @try {
                ok = [draw flushDrawWithError:&error];
            } @finally {
                irp_work = NULL;
                fpp_work = NULL;
            }
            assert(!ok && error && !fpp_fail_emit &&
                   [error.domain isEqualToString:@"test.float-proof.emit"] &&
                   [host isEqualToData:fpp_host()]);
            [actual addObjectsFromArray:@[ error.domain, @(error.code) ]];
            error = nil;
            require(irp_end(&work, &gpu, &error), error);
            [actual addObject:fpp_frame(pg)];
            /* Restored accepted spans also leave a Current-only key. Fresh
             * capture must rebuild once, then a new Begin may reuse it. */
            for (unsigned pass = 0; pass < 2; pass++) {
                require([draw beginWithError:&error] &&
                            irp_end(&work, &gpu, &error),
                        error);
                [actual addObject:fpp_frame(pg)];
            }
            if (!candidate)
                reference = actual;
            else
                assert([reference isEqualToArray:actual]);
            assert(irp_payload() <= 65536 && work.builds && gpu.records);
            builds[candidate] = work.builds;
            hits[candidate] = work.hits;
            records[candidate] = gpu.records;
            qemu_mutex_unlock(&pg->lock);
        }
    }
    assert(currentOnly[0] && currentOnly[1]);
    assert(builds[0] == 7 && builds[1] == 5 && !hits[0] && hits[1] == 2);
    assert(records[0] == 224 && records[1] == 224);
}
static void readonly_index_plan_reuse_pgraph_tests(void)
{
    Method methods[] = {
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            NSSelectorFromString(@"canReuseReadonlyIndexPlanForInput:prefix:")),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            NSSelectorFromString(
                @"readonlyIndicesForInput:prefix:remap:current:")),
        class_getInstanceMethod(
            NV2AMetalPGRAPHFetch.class,
            NSSelectorFromString(
                @"buildReadonlyIndices:prefix:remap:current:computed:")),
        class_getInstanceMethod(
            NV2AMetalEpochExecutor.class,
            @selector(encodeRasterState:attributeBuffer:first:count:
                      attributeFetch:commands:error:)),
        class_getInstanceMethod(
            NV2AMetalPixelDraw.class,
            @selector(encodeWithRenderEncoder:commands:error:))
    };
    IMP replacements[] = { (IMP)irp_reuse, (IMP)irp_indices, (IMP)irp_builder,
                           (IMP)fpp_epoch, (IMP)fpp_emit };
    IMP originals[ARRAY_SIZE(methods)];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++) {
        assert(methods[i]);
        originals[i] = method_getImplementation(methods[i]);
    }
    irp_reuse_original = (void *)originals[0];
    irp_indices_original = (void *)originals[1];
    irp_builder_original = (void *)originals[2];
    fpp_epoch_original = (void *)originals[3];
    fpp_emit_original = (void *)originals[4];
    for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
        method_setImplementation(methods[i], replacements[i]);
    @try {
        irp_repeated_pair(0);
        irp_repeated_pair(1);
        irp_repeated_pair(2);
        irp_lifecycle_pair();
        irp_repeated_pair(4);
    } @finally {
        irp_work = NULL;
        fpp_work = NULL;
        fpp_fail_emit = NO;
        for (unsigned i = 0; i < ARRAY_SIZE(methods); i++)
            method_setImplementation(methods[i], originals[i]);
    }
    groups += 5;
    puts(
        "PGRAPH readonly index-plan reuse: 5 exact GPU/frame/depth/query/"
        "Current/context/archive groups; fresh Begin/End descriptors, 6144/32, "
        "sequence/last, CPU/GPU-source fault/repair, prefix/Restore/late "
        "retry, "
        "monotone no-dup and unchanged 64KiB four-plan budget PASS");
}
#endif
