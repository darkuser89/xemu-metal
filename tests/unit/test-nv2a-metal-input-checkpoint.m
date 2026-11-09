/* CPU lifecycle checkpoint test; no Metal device/queue/dispatch.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "hw/xbox/nv2a/pgraph/metal/input-checkpoint.h"
#include <time.h>
static uint32_t raw(unsigned seed, unsigned index)
{
    return 0x9e3779b9u * (index + 1) + seed;
}
static void set(PGRAPHState *pg, unsigned kind, unsigned count, unsigned seed,
                float *buffers)
{
    memset(pg, 0, sizeof(*pg));
    if (count) {
        if (kind == 0) {
            pg->draw_arrays_length = 2;
            pg->draw_arrays_start[0] = 3;
            pg->draw_arrays_start[1] = 1000;
            pg->draw_arrays_count[0] = pg->draw_arrays_count[1] = count;
        }
        if (kind == 1)
            pg->inline_elements_length = count;
        if (kind == 2)
            pg->inline_buffer_length = count;
        if (kind == 3)
            pg->inline_array_length = count;
    }
    pg->compressed_attrs = (uint16_t)raw(seed, 0);
    pg->uniform_attrs = (uint16_t)raw(seed, 1);
    pg->swizzle_attrs = (uint16_t)raw(seed, 2);
    for (unsigned a = 0; a < 16; a++) {
        VertexAttribute *v = &pg->vertex_attributes[a];
        v->inline_buffer = buffers + a * 128 * 4;
        v->inline_buffer_populated = !!((raw(seed, 3) >> (a)) & 1);
        v->stride = a + 1;
        v->format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
        v->count = 4;
        v->size = 4;
        v->offset = 128 * a;
        v->dma_select = a & 1;
        for (unsigned k = 0; k < 4; k++) {
            uint32_t bits = raw(seed, a * 4 + k);
            memcpy(&v->inline_value[k], &bits, 4);
        }
    }
    pg->vsh_constants[191][0] = 0x7fa12345u;
    pg->vsh_constants_dirty[191] = true;
    pg->regs_[NV_PGRAPH_CONTROL_0] = raw(seed, 4);
    pg->draw_time = seed;
}
static void mutate_fetch(PGRAPHState *pg)
{
    pg->compressed_attrs = 0;
    for (unsigned a = 0; a < 16; a++) {
        pg->vertex_attributes[a].inline_buffer_populated = false;
        for (unsigned k = 0; k < 4; k++) {
            uint32_t bits = 0x7fa12345u + a * 4 + k;
            memcpy(&pg->vertex_attributes[a].inline_value[k], &bits, 4);
        }
    }
}
static void attribute_byte_tests(PGRAPHState *pg, float *buffers)
{
    set(pg, 0, 1, 42, buffers);
    VertexAttribute original[16];
    memcpy(original, pg->vertex_attributes, sizeof(original));
    uint16_t compressed = pg->compressed_attrs;
    unsigned accepted = 0, rejected = 0;
    for (unsigned attribute = 0; attribute < 16; attribute++)
        for (size_t byte = 0; byte < sizeof(VertexAttribute); byte++) {
            memcpy(pg->vertex_attributes, original, sizeof(original));
            pg->compressed_attrs = compressed;
            NSError *error = nil;
            NV2AMetalPGRAPHInputCheckpoint *checkpoint =
                [[NV2AMetalPGRAPHInputCheckpoint alloc]
                    initWithState:pg error:&error];
            assert(checkpoint && !error);
            mutate_fetch(pg);
            ((uint8_t *)&pg->vertex_attributes[attribute])[byte] ^= 1;
            VertexAttribute before[16];
            memcpy(before, pg->vertex_attributes, sizeof(before));
            size_t values = offsetof(VertexAttribute, inline_value),
                   populated = offsetof(VertexAttribute, inline_buffer_populated);
            BOOL permitted =
                (byte >= values && byte < values + sizeof(original[0].inline_value)) ||
                (byte >= populated && byte < populated +
                    sizeof(original[0].inline_buffer_populated));
            BOOL restored = [checkpoint restoreWithState:pg error:&error];
            if (permitted) {
                assert(restored && !error &&
                       !memcmp(pg->vertex_attributes, original, sizeof(original)) &&
                       pg->compressed_attrs == compressed);
                accepted++;
            } else {
                assert(!restored && error &&
                       !memcmp(pg->vertex_attributes, before, sizeof(before)) &&
                       !pg->compressed_attrs);
                rejected++;
            }
        }
    assert(accepted + rejected == 16 * sizeof(VertexAttribute));
    printf("Input checkpoint layout bytes: %u Current/flag bytes restored, "
           "%u other layout/padding bytes rejected atomically PASS\n",
           accepted, rejected);
}
static void checkpoint_benchmark(void)
{
    PGRAPHState *pg = calloc(1, sizeof(*pg));
    float *buffers = calloc(16 * 128 * 4, sizeof(*buffers));
    assert(pg && buffers);
    const unsigned ranges[] = { 0, 2, 1250 };
    for (unsigned shape = 0; shape < 3; shape++) {
        set(pg, ranges[shape] ? 0 : 1, 1, 42, buffers);
        pg->draw_arrays_length = ranges[shape];
        assert(ranges[shape] <= ARRAY_SIZE(pg->draw_arrays_start));
        for (unsigned i = 0; i < ranges[shape]; i++) {
            pg->draw_arrays_start[i] = i * 4;
            pg->draw_arrays_count[i] = 1;
        }
        struct timespec start, finish;
        assert(!clock_gettime(CLOCK_MONOTONIC, &start));
        for (unsigned i = 0; i < 10000; i++) {
            @autoreleasepool {
                NSError *error = nil;
                NV2AMetalPGRAPHInputCheckpoint *checkpoint =
                    [[NV2AMetalPGRAPHInputCheckpoint alloc]
                        initWithState:pg error:&error];
                assert(checkpoint && !error);
                mutate_fetch(pg);
                assert([checkpoint restoreWithState:pg error:&error] && !error);
            }
        }
        assert(!clock_gettime(CLOCK_MONOTONIC, &finish));
        double seconds = finish.tv_sec - start.tv_sec +
                         (finish.tv_nsec - start.tv_nsec) * 1e-9;
        printf("Input checkpoint CPU benchmark: 10000 capture/restore pairs, "
               "%u ranges %.3f ms PASS; no guest or GPU timing\n",
               ranges[shape], seconds * 1000);
    }
    free(buffers);
    free(pg);
}
int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "--checkpoint-benchmark")) {
            checkpoint_benchmark();
            return 0;
        }
        PGRAPHState *pg = calloc(1, sizeof(*pg)),
                    *expected = malloc(sizeof(*pg)),
                    *other = calloc(1, sizeof(*pg));
        float *buffers = malloc(16 * 128 * 16);
        assert(pg && expected && other && buffers);
        for (unsigned k = 0; k < 16 * 128 * 4; k++) {
            uint32_t bits = raw(42, k);
            memcpy(&buffers[k], &bits, 4);
        }
        unsigned cases = 0, rejections = 0;
        const unsigned counts[] = { 0, 1, 2, 3, 7, 16, 32, 65, 128 };
        for (unsigned kind = 0; kind < 4; kind++)
            for (unsigned n = 0; n < 9; n++)
                for (unsigned seed = 0; seed < 32; seed++) {
                    @autoreleasepool {
                        set(pg, kind, counts[n], seed, buffers);
                        memcpy(expected, pg, sizeof(*pg));
                        NSError *error = nil;
                        NV2AMetalPGRAPHInputCheckpoint *c =
                            [[NV2AMetalPGRAPHInputCheckpoint alloc]
                                initWithState:pg
                                        error:&error];
                        assert(c && !error);
                        mutate_fetch(pg);
                        /* Context side effects are unrelated to fetch rollback.
                         */
                        pg->vsh_constants[191][0] =
                            expected->vsh_constants[191][0] = 0x80000000u;
                        pg->vsh_constants_dirty[10] =
                            expected->vsh_constants_dirty[10] = true;
                        error = nil;
                        assert(![c restoreWithState:other error:&error] &&
                               error);
                        rejections++;
                        error = nil;
                        assert([c restoreWithState:pg error:&error] && !error);
                        assert(!memcmp(pg, expected, sizeof(*pg)));
                        error = nil;
                        assert(![c restoreWithState:pg error:&error] && error);
                        rejections++;
                        cases++;
                    }
                }
        for (unsigned mutation = 0; mutation < 8; mutation++) {
            set(pg, 0, 3, mutation, buffers);
            NSError *error = nil;
            NV2AMetalPGRAPHInputCheckpoint *c =
                [[NV2AMetalPGRAPHInputCheckpoint alloc] initWithState:pg
                                                                error:&error];
            assert(c && !error);
            mutate_fetch(pg);
            if (mutation == 0)
                pg->draw_arrays_length++;
            if (mutation == 1)
                pg->inline_elements_length++;
            if (mutation == 2)
                pg->inline_buffer_length++;
            if (mutation == 3)
                pg->inline_array_length++;
            if (mutation == 4)
                pg->draw_arrays_start[1]++;
            if (mutation == 5)
                pg->draw_arrays_count[1]++;
            if (mutation == 6)
                pg->vertex_attributes[7].inline_buffer += 4;
            if (mutation == 7)
                pg->vertex_attributes[12].stride++;
            memcpy(expected, pg, sizeof(*pg));
            error = nil;
            assert(![c restoreWithState:pg error:&error] && error);
            assert(!memcmp(pg, expected, sizeof(*pg)));
            rejections++;
        }
        NSError *error = nil;
        assert(![[NV2AMetalPGRAPHInputCheckpoint alloc] initWithState:NULL
                                                                error:&error] &&
               error);
        rejections++;
        for (unsigned mutation = 0; mutation < 6; mutation++) {
            set(pg, 2, 3, mutation, buffers);
            if (mutation == 0)
                pg->draw_arrays_length = ARRAY_SIZE(pg->draw_arrays_start) + 1;
            if (mutation == 1)
                pg->inline_elements_length = NV2A_MAX_BATCH_LENGTH + 1;
            if (mutation == 2)
                pg->inline_buffer_length = NV2A_MAX_BATCH_LENGTH + 1;
            if (mutation == 3)
                pg->inline_array_length = NV2A_MAX_BATCH_LENGTH + 1;
            if (mutation == 4)
                pg->inline_elements_length = 1;
            if (mutation == 5) {
                pg->vertex_attributes[5].inline_buffer_populated = true;
                pg->vertex_attributes[5].inline_buffer = NULL;
            }
            memcpy(expected, pg, sizeof(*pg));
            error = nil;
            assert(![[NV2AMetalPGRAPHInputCheckpoint alloc]
                       initWithState:pg
                               error:&error] &&
                   error);
            assert(!memcmp(pg, expected, sizeof(*pg)));
            rejections++;
        }
        for (unsigned k = 0; k < 16 * 128 * 4; k++) {
            uint32_t bits;
            memcpy(&bits, &buffers[k], 4);
            assert(bits == raw(42, k));
        }
        assert(cases == 1152 && rejections == 2319);
        attribute_byte_tests(pg, buffers);
        printf("Input checkpoints: %u full-PGRAPH byte comparisons/%u "
               "cross-owner, stale, repeat and invalid-input rejections PASS; "
               "source buffers and unrelated context writes preserved; no "
               "Metal device/queue/dispatch\n",
               cases, rejections);
        free(buffers);
        free(pg);
        free(expected);
        free(other);
    }
    return 0;
}
