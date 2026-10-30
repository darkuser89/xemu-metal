/* PGRAPH DMA/packed/inline/indexed fetch with real native GPU stages.
 * VM/DMA registration is mocked; no VM/app/window is started.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "hw/xbox/nv2a/pgraph/metal/fetch-pgraph.h"
#import "hw/xbox/nv2a/pgraph/metal/clear.h"
#import "hw/xbox/nv2a/pgraph/metal/vertex-pgraph.h"
#import "hw/xbox/nv2a/pgraph/metal/pixel-pgraph.h"
#import "hw/xbox/nv2a/pgraph/metal/geometry.h"

#include "test-metal-idx.h"

static NV2AState *state;
static NV2AMetalSurfaceCache *surfaces;
static NV2AMetalPGRAPHFetch *adapter;
static DMAObject dma_a, dma_b;
static bool dirty_last;
static unsigned groups, reads, notifications;
static unsigned chains;
bool tcg_allowed = true;
uint64_t memory_region_size(MemoryRegion *mr)
{
    assert(mr == state->vram);
    return 65536;
}
DMAObject nv_dma_load(NV2AState *d, hwaddr object)
{
    assert(d == state && (object == 16 || object == 32));
    return object == 16 ? dma_a : dma_b;
}
bool memory_region_test_and_clear_dirty(MemoryRegion *mr, hwaddr address,
                                        hwaddr length, unsigned client)
{
    assert(mr == state->vram && client == DIRTY_MEMORY_NV2A && length &&
           address <= 65536 && length <= 65536 - address);
    reads++;
    bool dirty = dirty_last && address + length == 65536;
    if (dirty)
        dirty_last = false;
    return dirty;
}
void memory_region_set_client_dirty(MemoryRegion *mr, hwaddr address,
                                    hwaddr length, unsigned client)
{
    assert(mr == state->vram && client == DIRTY_MEMORY_NV2A &&
           address < 65536 && length <= 65536 - address);
    dirty_last = true;
}
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "PGRAPH fetch: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static void scalar(float actual, float expected)
{
    if (!isfinite(actual) || fabsf(actual - expected) > .000001f) {
        fprintf(stderr, "Attribute %g expected %g\n", actual, expected);
        abort();
    }
}
static void reset(void)
{
    memset(&state->pgraph, 0, sizeof(state->pgraph));
    PGRAPHState *pg = &state->pgraph;
    pg->dma_vertex_a = 16;
    pg->dma_vertex_b = 32;
    dma_a = (DMAObject){ .dma_class = NV_DMA_IN_MEMORY_CLASS,
                         .address = 1024,
                         .limit = 65535 };
    dma_b = (DMAObject){ .dma_class = NV_DMA_IN_MEMORY_CLASS,
                         .address = 8192,
                         .limit = 65535 };
    for (unsigned i = 0; i < 16; i++)
        pg->vertex_attributes[i].inline_value[3] = 1;
}
static NSArray<NV2AMetalPGRAPHFetchBatch *> *prepare(void)
{
    NSError *error = nil;
    NSArray *b = [adapter prepareWithError:&error];
    require(b != nil, error);
    assert(!surfaces.commands.commandBuffer);
    return b;
}
static const NV2AMetalProgramInput *values(NV2AMetalPGRAPHFetchBatch *b)
{
    assert(b.fetch.attributes && b.fetch.faults);
    const uint32_t *faults = b.fetch.faults.contents;
    for (NSUInteger i = 0; i < b.fetch.vertexCount; i++)
        assert(!faults[i]);
    return b.fetch.attributes.contents;
}
static void cpu_write(NSUInteger address, NSUInteger length)
{
    NSError *error = nil;
    require([surfaces prepareCPUAccessAtAddress:address
                                         length:length
                                          write:YES
                                          error:&error],
            error);
}
static void dma_stream(void)
{
    reset();
    PGRAPHState *pg = &state->pgraph;
    pg->vertex_attributes[0] =
        (VertexAttribute){ .offset = 64,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 4,
                           .stride = 16 };
    pg->vertex_attributes[3] =
        (VertexAttribute){ .dma_select = true,
                           .offset = 64,
                           .format =
                               NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
                           .size = 1,
                           .count = 4,
                           .stride = 4 };
    cpu_write(1088, 96);
    cpu_write(8256, 24);
    for (unsigned i = 0; i < 6; i++) {
        float p[4] = { i + .25f, i + .5f, i + .75f, 1 };
        memcpy(state->vram_ptr + 1088 + i * 16, p, 16);
        unsigned char c[4] = { i, 0x20 + i, 0x80 + i, 255 };
        memcpy(state->vram_ptr + 8256 + i * 4, c, 4);
    }
    dma_a.limit = 159;
    dma_b.limit = 87;
}

static void current_publication_tests(void)
{
    for (unsigned failure = 0; failure < 4; failure++) {
        dma_stream();
        PGRAPHState *pg = &state->pgraph;
        pg->draw_arrays_length = 2;
        pg->draw_arrays_start[0] = 4;
        pg->draw_arrays_count[0] = 2;
        pg->draw_arrays_start[1] = 1;
        pg->draw_arrays_count[1] = 2;
        float before[16][4];
        for (unsigned i = 0; i < 16; i++)
            memcpy(before[i], pg->vertex_attributes[i].inline_value, 16);
        NSError *error = nil;
        NSArray<NV2AMetalPGRAPHFetchBatch *> *b =
            [adapter encodeWithError:&error];
        require(b != nil, error);
        assert(b[0].fetch.hasCurrent && !b[1].fetch.hasCurrent);
        for (unsigned i = 0; i < 16; i++)
            assert(
                !memcmp(before[i], pg->vertex_attributes[i].inline_value, 16));
        if (!failure) {
            [adapter cancel];
        } else {
            /* Inject only after GPU completion: this exercises frontend fault
             * ordering without racing the GPU's writes to shared memory. */
            require([surfaces submitWithError:&error], error);
            require([surfaces waitUntilIdleWithError:&error], error);
            unsigned batch = failure == 2 ? 1 : 0;
            unsigned slot = failure == 3 ? b[0].fetch.vertexCount : 0;
            ((uint32_t *)b[batch].fetch.faults.contents)[slot] = 1;
            if (slot < b[batch].fetch.vertexCount)
                *(uint32_t *)((uint8_t *)b[batch].fetch.faults.contents +
                              b[batch].fetch.faultSummaryOffset) = 1;
            assert(![adapter completeWithError:&error] && error);
            assert([error.localizedDescription
                containsString:failure == 3 ? @"current-attribute" :
                                              @"vertex fetch"]);
        }
        for (unsigned i = 0; i < 16; i++)
            assert(
                !memcmp(before[i], pg->vertex_attributes[i].inline_value, 16));
        b = prepare();
        assert(b.count == 2);
        scalar(pg->vertex_attributes[0].inline_value[0], 5.25f);
        scalar(pg->vertex_attributes[3].inline_value[0], 5 / 255.f);
        groups++;
    }
    puts("Metal4 fused Current publication: cancel, first/later/current fault, "
         "unchanged CPU state and four retries PASS");
}

static void submitted_current_tests(void)
{
    for (unsigned failure = 0; failure < 3; failure++) {
        dma_stream();
        PGRAPHState *pg = &state->pgraph;
        pg->draw_arrays_length = 1;
        pg->draw_arrays_start[0] = 1;
        pg->draw_arrays_count[0] = 2;
        float before[16][4];
        for (unsigned i = 0; i < 16; i++)
            memcpy(before[i], pg->vertex_attributes[i].inline_value, 16);
        NSError *error = nil;
        NSArray<NV2AMetalPGRAPHFetchBatch *> *b =
            [adapter encodeWithError:&error];
        require(b != nil, error);
        require([adapter submitWithError:&error], error);
        NV2AMetalSubmission *receipt = surfaces.commands.lastSubmitted;
        assert(receipt && !surfaces.commands.commandBuffer);
        assert(![adapter submitWithError:&error] && error);
        for (unsigned i = 0; i < 16; i++)
            assert(
                !memcmp(before[i], pg->vertex_attributes[i].inline_value, 16));
        /* Complete only the GPU producer before injecting a fault. Current
         * still belongs to completeWithError, never to feedback or submit. */
        require([surfaces.commands waitForSubmission:receipt error:&error],
                error);
        if (failure)
            ((uint32_t *)b[0]
                 .fetch.faults
                 .contents)[failure == 1 ? 0 : b[0].fetch.vertexCount] = 1;
        if (failure == 1)
            *(uint32_t *)((uint8_t *)b[0].fetch.faults.contents +
                          b[0].fetch.faultSummaryOffset) = 1;
        require([surfaces prepareGPUReadAtAddress:60000 length:4 error:&error],
                error);
        id recording = surfaces.commands.commandBuffer;
        NV2AMetalSurfaceRecording *token = surfaces.recording;
        assert(recording && token && !token.submitted && !token.cancelled);
        BOOL ok = [adapter completeWithError:&error];
        if (failure) {
            assert(!ok && error && token.cancelled &&
                   !surfaces.commands.commandBuffer);
            for (unsigned i = 0; i < 16; i++)
                assert(!memcmp(before[i], pg->vertex_attributes[i].inline_value,
                               16));
            require([adapter prepareWithError:&error] != nil, error);
        } else {
            require(ok, error);
            assert(surfaces.commands.commandBuffer == recording &&
                   surfaces.recording == token && !token.cancelled &&
                   !token.submitted);
            scalar(pg->vertex_attributes[0].inline_value[0], 2.25f);
            scalar(pg->vertex_attributes[3].inline_value[0], 2 / 255.f);
            [surfaces cancel];
        }
        groups++;
    }
    puts("Submitted Fetch:Current unchanged until owner completion;live later "
         "recording preserved;duplicate submit rejected;fetch/Current faults "
         "cancel only later work,preserve attributes and retry PASS");
}

static void array_and_index_tests(void)
{
    dma_stream();
    PGRAPHState *pg = &state->pgraph;
    pg->draw_arrays_length = 2;
    pg->draw_arrays_start[0] = 4;
    pg->draw_arrays_count[0] = 2;
    pg->draw_arrays_start[1] = 1;
    pg->draw_arrays_count[1] = 2;
    NSArray<NV2AMetalPGRAPHFetchBatch *> *b = prepare();
    assert(b.count == 2 && b[0].firstVertex == 4 && !b[0].indexed);
    assert(b[0].fetch.hasCurrent && !b[1].fetch.hasCurrent);
    const NV2AMetalProgramInput *v = values(b[0]);
    scalar(v[0].attributes[0][0], 4.25f);
    scalar(v[1].attributes[3][0], 0x85 / 255.f);
    scalar(v[1].attributes[3][2], 5 / 255.f);
    v = values(b[1]);
    scalar(v[0].attributes[0][0], 1.25f);
    scalar(pg->vertex_attributes[0].inline_value[0], 5.25f);
    scalar(pg->vertex_attributes[3].inline_value[0], 5 / 255.f);
    scalar(pg->vertex_attributes[3].inline_value[2], 0x85 / 255.f);
    groups++;
    dma_stream();
    pg->inline_elements_length = 4;
    uint32_t indices[] = { 3, 1, 4, 2 };
    memcpy(pg->inline_elements, indices, sizeof(indices));
    b = prepare();
    assert(b.count == 1 && b[0].indexed && b[0].fetch.vertexCount == 4);
    assert(b[0].fetch.hasCurrent);
    v = values(b[0]);
    for (unsigned i = 0; i < 4; i++)
        scalar(v[i].attributes[0][0], indices[i] + .25f);
    scalar(pg->vertex_attributes[0].inline_value[0], 2.25f);
    groups++;
    dma_stream();
    pg->vertex_attributes[0].stride = pg->vertex_attributes[3].stride = 0;
    dma_a.limit = 79;
    dma_b.limit = 67;
    pg->draw_arrays_length = 1;
    pg->draw_arrays_start[0] = 200;
    pg->draw_arrays_count[0] = 3;
    b = prepare();
    v = values(b[0]);
    for (unsigned i = 0; i < 3; i++) {
        scalar(v[i].attributes[0][0], .25f);
        scalar(v[i].attributes[3][0], 0);
        scalar(v[i].attributes[3][2], 0x80 / 255.f);
    }
    scalar(pg->vertex_attributes[0].inline_value[0], .25f);
    groups++;
}
static void packed_and_inline_buffer_tests(void)
{
    reset();
    PGRAPHState *pg = &state->pgraph;
    pg->vertex_attributes[0] =
        (VertexAttribute){ .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 3 };
    pg->vertex_attributes[3] =
        (VertexAttribute){ .format =
                               NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
                           .size = 1,
                           .count = 4 };
    for (unsigned i = 0; i < 2; i++) {
        float p[3] = { i + 1, i + 2, i + 3 };
        memcpy((unsigned char *)pg->inline_array + i * 16, p, 12);
        unsigned char c[] = { 1 + i, 2 + i, 3 + i, 4 + i };
        memcpy((unsigned char *)pg->inline_array + i * 16 + 12, c, 4);
    }
    pg->inline_array_length =
        9; /* Two complete16-byte tuples plus a discarded4-byte tail. */
    NSArray<NV2AMetalPGRAPHFetchBatch *> *b = prepare();
    assert(b[0].fetch.vertexCount == 2);
    const NV2AMetalProgramInput *v = values(b[0]);
    scalar(v[1].attributes[0][0], 2);
    scalar(v[1].attributes[0][3], 1);
    scalar(v[1].attributes[3][0], 4 / 255.f);
    scalar(pg->vertex_attributes[3].inline_value[0], 2 / 255.f);
    groups++;
    reset();
    float positions[2][4] = { { 1, 2, 3, 1 }, { 4, 5, 6, 1 } },
          colors[2][4] = { { 1, 0, 0, 1 }, { 0, 1, 0, 1 } };
    pg->inline_buffer_length = 2;
    pg->vertex_attributes[0].inline_buffer_populated =
        pg->vertex_attributes[3].inline_buffer_populated = true;
    pg->vertex_attributes[0].inline_buffer = &positions[0][0];
    pg->vertex_attributes[3].inline_buffer = &colors[0][0];
    b = prepare();
    v = values(b[0]);
    scalar(v[0].attributes[3][0], 1);
    scalar(v[1].attributes[3][1], 1);
    scalar(pg->vertex_attributes[0].inline_value[0], 4);
    assert(!pg->vertex_attributes[0].inline_buffer_populated &&
           !pg->vertex_attributes[3].inline_buffer_populated);
    groups++;
}
static void packed_normal_and_overlap_tests(void)
{
    reset();
    PGRAPHState *pg = &state->pgraph;
    const uint32_t packed[2] = { 0x80200400, 0x80200400 };
    cpu_write(1088, sizeof(packed));
    memcpy(state->vram_ptr + 1088, packed, sizeof(packed));
    pg->vertex_attributes[2] =
        (VertexAttribute){ .offset = 64,
                           .format =
                               NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP,
                           .size = 4,
                           .count = 1,
                           .stride = 4 };
    dma_a.limit = 71;
    pg->draw_arrays_length = 1;
    pg->draw_arrays_count[0] = 2;
    NSArray<NV2AMetalPGRAPHFetchBatch *> *b = prepare();
    const NV2AMetalProgramInput *v = values(b[0]);
    scalar(v[1].attributes[2][0], -1024.f / 1023);
    scalar(v[1].attributes[2][1], -1024.f / 1023);
    scalar(v[1].attributes[2][2], -512.f / 511);
    for (unsigned i = 0; i < 3; i++)
        scalar(pg->vertex_attributes[2].inline_value[i], -1);
    scalar(pg->vertex_attributes[2].inline_value[3], 1);
    groups++;
    reset();
    const float overlapping[] = { 1, 2, 3, 4, 5 };
    cpu_write(1088, sizeof(overlapping));
    memcpy(state->vram_ptr + 1088, overlapping, sizeof(overlapping));
    pg->vertex_attributes[0] =
        (VertexAttribute){ .offset = 64,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 4,
                           .stride = 4 };
    dma_a.limit = 83;
    pg->draw_arrays_length = 1;
    pg->draw_arrays_count[0] = 2;
    b = prepare();
    v = values(b[0]);
    for (unsigned i = 0; i < 4; i++) {
        scalar(v[0].attributes[0][i], i + 1);
        scalar(v[1].attributes[0][i], i + 2);
        scalar(pg->vertex_attributes[0].inline_value[i], i + 2);
    }
    groups++;
}
static void gpu_alias_and_last_page_tests(void)
{
    reset();
    PGRAPHState *pg = &state->pgraph;
    NSError *error = nil;
    NV2AMetalSurfaceConfig c = { .format = 8,
                                 .width = 4,
                                 .height = 4,
                                 .pitch = 16,
                                 .scale = 1,
                                 .color = YES };
    NV2AMetalCachedSurface *s = [surfaces prepareSurfaceAtAddress:12288
                                                           config:&c
                                                            frame:1
                                                            error:&error];
    require(s != nil, error);
    NV2AMetalClear *clear =
        [[NV2AMetalClear alloc] initWithDevice:surfaces.commands.device
                                         error:&error];
    require(clear != nil, error);
    NV2AMetalClearConfig clearconfig = { .parameter = NV097_CLEAR_SURFACE_COLOR,
                                         .rect = { 0, 0, 4, 4 },
                                         .uniforms = { .color = { 1, 0, 0, 1 },
                                                       .depth = 0 } };
    require([clear encodeColor:s.transfer.texture
                          zeta:nil
                        config:&clearconfig
                      commands:surfaces.commands
                         error:&error],
            error);
    require([surfaces markWritten:s error:&error], error);
    pg->vertex_attributes[3] =
        (VertexAttribute){ .dma_select = true,
                           .offset = 4096,
                           .format =
                               NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
                           .size = 1,
                           .count = 4,
                           .stride = 4 };
    pg->draw_arrays_length = 1;
    pg->draw_arrays_count[0] = 3;
    unsigned before = notifications;
    NSArray<NV2AMetalPGRAPHFetchBatch *> *b = prepare();
    const NV2AMetalProgramInput *v = values(b[0]);
    scalar(v[0].attributes[3][0], 1);
    scalar(v[0].attributes[3][2], 0);
    scalar(pg->vertex_attributes[3].inline_value[0], 0);
    scalar(pg->vertex_attributes[3].inline_value[2], 1);
    assert(notifications == before + 1 && !s.dirty);
    groups++;
    reset();
    dma_a.address = 0;
    dma_a.limit = 65535;
    tcg_allowed = false;
    float p[] = { 3.25f, 4.5f, 5.75f, 1 };
    memcpy(state->vram_ptr + 65520, p, 16);
    dirty_last = true;
    pg->vertex_attributes[0] =
        (VertexAttribute){ .offset = 65520,
                           .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 4,
                           .stride = 16 };
    pg->draw_arrays_length = 1;
    pg->draw_arrays_count[0] = 1;
    b = prepare();
    v = values(b[0]);
    scalar(v[0].attributes[0][0], 3.25f);
    assert(!dirty_last);
    tcg_allowed = true;
    groups++;
}
static void bounded_core_test(void)
{
    NSError *error = nil;
    require([surfaces prepareGPUReadAtAddress:0 length:0 error:&error], error);
    NV2AMetalVertexFetch *fetch =
        [[NV2AMetalVertexFetch alloc] initWithDevice:surfaces.commands.device
                                               error:&error];
    require(fetch != nil, error);
    float p[2][4] = { { 1, 2, 3, 1 }, { 4, 5, 6, 1 } };
    id<MTLBuffer> buffer = [surfaces.commands.device
        newBufferWithBytes:p
                    length:sizeof(p)
                   options:MTLResourceStorageModeShared];
    assert(buffer);
    NV2AMetalAttributeSource sources[16] = { 0 };
    sources[0] = (NV2AMetalAttributeSource){
        .buffer = buffer,
        .byteLength = 16,
        .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        .count = 4,
        .stride = 16
    };
    assert(![fetch encodeSources:sources
                           count:2
                     firstVertex:0
                         indices:nil
                     indexOffset:0
                       indexSize:0
                        commands:surfaces.commands
                           error:&error]);
    uint32_t index = 1;
    id<MTLBuffer> indices = [surfaces.commands.device
        newBufferWithBytes:&index
                    length:4
                   options:MTLResourceStorageModeShared];
    assert(indices);
    NV2AMetalFetchResult *r = [fetch encodeSources:sources
                                             count:1
                                       firstVertex:0
                                           indices:indices
                                       indexOffset:0
                                         indexSize:4
                                          commands:surfaces.commands
                                             error:&error];
    require(r != nil, error);
    require([surfaces submitWithError:&error], error);
    require([surfaces waitUntilIdleWithError:&error], error);
    assert(*(uint32_t *)r.faults.contents == 1);
    groups++;
}
static void idx_bits(float value, uint32_t expected)
{
    uint32_t actual;
    memcpy(&actual, &value, sizeof(actual));
    if (actual != expected) {
        fprintf(stderr, "PGRAPH IDX raw: got %08x, expected %08x\n", actual,
                expected);
        abort();
    }
}

static void idx_normalized_paths(void)
{
    enum { Count = sizeof(idx_short) / sizeof(idx_short[0]) };
    NSError *error = nil;
    NV2AMetalCommands *commands = surfaces.commands;
    NV2AMetalVertexProgram *program =
        [[NV2AMetalVertexProgram alloc] initWithDevice:commands.device
                                                 error:&error];
    require(program != nil, error);
    unsigned checked = 0, cases = 0;
    for (unsigned path = 0; path < 5; path++) {
        for (unsigned count = 1; count <= 4; count++) {
            for (unsigned d3d = 0; d3d < 2; d3d++) {
                reset();
                PGRAPHState *pg = &state->pgraph;
                unsigned stride = count * 2 + 4;
                float decoded[2][Count][4];
                cpu_write(1089, Count * 9);
                cpu_write(8257, Count * 5);
                for (unsigned i = 0; i < Count; i++) {
                    for (unsigned k = 0; k < 4; k++) {
                        unsigned sample = (i + 17 * k) % Count;
                        unsigned shortCode = idx_short[sample].code;
                        unsigned byteCode = (i + 31 * k) & 255;
                        state->vram_ptr[1089 + i * 9 + 2 * k] = shortCode;
                        state->vram_ptr[1089 + i * 9 + 2 * k + 1] =
                            shortCode >> 8;
                        state->vram_ptr[8257 + i * 5 + k] = byteCode;
                        if (k < count) {
                            ((uint8_t *)pg->inline_array)[i * stride + 2 * k] =
                                shortCode;
                            ((uint8_t *)
                                 pg->inline_array)[i * stride + 2 * k + 1] =
                                shortCode >> 8;
                        }
                        ((uint8_t *)
                             pg->inline_array)[i * stride + count * 2 + k] =
                            byteCode;
                        uint32_t norm = k < count ? idx_short[sample].bits :
                                        k == 3    ? 0x3f800000u :
                                                    0;
                        memcpy(&decoded[0][i][k], &norm, 4);
                        norm = idx_ubyte[byteCode];
                        memcpy(&decoded[1][i][k], &norm, 4);
                    }
                }
                pg->vertex_attributes[2] = (VertexAttribute){
                    .offset = 65,
                    .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1,
                    .size = 2,
                    .count = count,
                    .stride = 9
                };
                pg->vertex_attributes[3] = (VertexAttribute){
                    .dma_select = true,
                    .offset = 65,
                    .format =
                        d3d ? NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D :
                              NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
                    .size = 1,
                    .count = 4,
                    .stride = 5
                };
                unsigned pivot = Count - 1;
                if (path == 0) {
                    pg->draw_arrays_length = 1;
                    pg->draw_arrays_count[0] = Count;
                } else if (path == 1) {
                    pg->inline_elements_length = Count;
                    for (unsigned i = 0; i < Count; i++)
                        pg->inline_elements[i] = (Count - 1 - i + 1) % Count;
                    pivot = pg->inline_elements[Count - 1];
                } else if (path == 2) {
                    pg->inline_array_length = (Count * stride + 3) / 4;
                } else if (path == 3) {
                    pg->inline_buffer_length = Count;
                    for (unsigned a = 0; a < 2; a++) {
                        pg->vertex_attributes[a + 2].inline_buffer =
                            &decoded[a][0][0];
                        pg->vertex_attributes[a + 2].inline_buffer_populated =
                            true;
                    }
                } else {
                    pg->draw_arrays_length = 1;
                    pg->draw_arrays_count[0] = Count;
                    for (unsigned a = 0; a < 2; a++) {
                        pg->vertex_attributes[a + 2].count = 0;
                        memcpy(pg->vertex_attributes[a + 2].inline_value,
                               decoded[a][pivot], 16);
                    }
                }
                NSArray<NV2AMetalPGRAPHFetchBatch *> *batches = prepare();
                assert(batches.count == 1 &&
                       batches[0].fetch.vertexCount == Count);
                const NV2AMetalProgramInput *out = values(batches[0]);
                uint32_t expected[Count][2][4];
                for (unsigned i = 0; i < Count; i++) {
                    unsigned vertex = path == 1 ? pg->inline_elements[i] :
                                      path == 4 ? pivot :
                                                  i;
                    for (unsigned k = 0; k < 4; k++) {
                        unsigned sample = (vertex + 17 * k) % Count;
                        expected[i][0][k] = k < count ? idx_short[sample].bits :
                                            k == 3    ? 0x3f800000u :
                                                        0;
                        unsigned component =
                            d3d && path < 3 && k != 1 && k != 3 ? 2 - k : k;
                        expected[i][1][k] =
                            idx_ubyte[(vertex + 31 * component) & 255];
                        for (unsigned a = 0; a < 2; a++) {
                            idx_bits(out[i].attributes[a + 2][k],
                                     expected[i][a][k]);
                            checked++;
                        }
                    }
                }
                for (unsigned a = 0; a < 2; a++) {
                    for (unsigned k = 0; k < 4; k++) {
                        uint32_t current;
                        memcpy(&current, &decoded[a][pivot][k], 4);
                        idx_bits(pg->vertex_attributes[a + 2].inline_value[k],
                                 current);
                    }
                }
                NV2AMetalProgramUniforms u = { 0 };
                u.surface_size[0] = u.surface_size[1] = 8;
                u.zmax = 65535;
                u.point_scale = u.point_size = 1;
                uint32_t tokens[2][4] = { 0 };
                for (unsigned a = 0; a < 2; a++) {
                    tokens[a][1] = 1 << 21 | (a + 2) << 9 | 27;
                    tokens[a][2] = 2u << 26;
                    tokens[a][3] = 1 << 11 | (a + 3) << 3 | 15 << 12 | a;
                }
                require([commands beginWithError:&error] != nil, error);
                NV2AMetalProgramResult *result =
                    [program encodeTokens:&tokens[0][0]
                                   length:2
                                 uniforms:&u
                               attributes:batches[0].fetch.attributes
                                    count:Count
                                 commands:commands
                                    error:&error];
                require(result != nil, error);
                require([commands submitWithError:&error], error);
                require([commands waitUntilIdleWithError:&error], error);
                const NV2AMetalProgramOutput *raw = result.registers.contents;
                for (unsigned i = 0; i < Count; i++) {
                    assert(raw[i].fault == 0);
                    for (unsigned a = 0; a < 2; a++)
                        for (unsigned k = 0; k < 4; k++) {
                            idx_bits(raw[i].registers[a + 3][k],
                                     expected[i][a][k]);
                            checked++;
                        }
                }
                if (path == 3)
                    assert(!pg->vertex_attributes[2].inline_buffer_populated &&
                           !pg->vertex_attributes[3].inline_buffer_populated);
                cases++;
                groups++;
            }
        }
    }
    printf(
        "Metal4 IDX PGRAPH: %u typed/current/decoded groups, %u raw channels "
        "including native MOV handoff PASS\n",
        cases, checked);
}

static void full_chain_tests(void)
{
    NSError *error = nil;
    NV2AMetalCommands *commands = surfaces.commands;
    NV2AMetalVertexProgram *program =
        [[NV2AMetalVertexProgram alloc] initWithDevice:commands.device
                                                 error:&error];
    NV2AMetalVertexFixed *fixed =
        [[NV2AMetalVertexFixed alloc] initWithDevice:commands.device
                                               error:&error];
    NV2AMetalGeometry *geometry =
        [[NV2AMetalGeometry alloc] initWithDevice:commands.device error:&error];
    NV2AMetalPixelShader *pixel =
        [[NV2AMetalPixelShader alloc] initWithDevice:commands.device
                                         colorFormat:MTLPixelFormatRGBA32Float
                                         depthFormat:MTLPixelFormatInvalid
                                         sampleCount:1
                                               error:&error];
    require(program && fixed && geometry && pixel, error);
    const float positions[3][4] = { { 0, 0, 32768, 1 },
                                    { 8, 0, 32768, 1 },
                                    { 0, 8, 32768, 1 } };
    float colors[3][4] = { { 0, 1, 0, 1 }, { 0, 1, 0, 1 }, { 0, 1, 0, 1 } };
    for (unsigned path = 0; path < 4; path++) {
        for (unsigned programmable = 0; programmable < 2; programmable++) {
            dma_stream();
            PGRAPHState *pg = &state->pgraph;
            cpu_write(1088, sizeof(positions));
            memcpy(state->vram_ptr + 1088, positions, sizeof(positions));
            cpu_write(8256, 12);
            for (unsigned i = 0; i < 3; i++) {
                const uint8_t green[4] = { 0, 255, 0, 255 };
                memcpy(state->vram_ptr + 8256 + i * 4, green, 4);
                memcpy((uint8_t *)pg->inline_array + i * 20, positions[i], 16);
                memcpy((uint8_t *)pg->inline_array + i * 20 + 16, green, 4);
            }
            switch (path) {
            case 0:
                pg->draw_arrays_length = 1;
                pg->draw_arrays_count[0] = 3;
                break;
            case 1:
                pg->inline_elements_length = 3;
                pg->inline_elements[0] = 2;
                pg->inline_elements[1] = 0;
                pg->inline_elements[2] = 1;
                break;
            case 2:
                pg->inline_array_length = 15;
                break;
            case 3:
                pg->inline_buffer_length = 3;
                pg->vertex_attributes[0].inline_buffer =
                    (float *)&positions[0][0];
                pg->vertex_attributes[3].inline_buffer = &colors[0][0];
                pg->vertex_attributes[0].inline_buffer_populated =
                    pg->vertex_attributes[3].inline_buffer_populated = true;
                break;
            }
            NSArray<NV2AMetalPGRAPHFetchBatch *> *batches = prepare();
            assert(batches.count == 1 && batches[0].fetch.vertexCount == 3);
            pg->primitive_mode = PRIM_TYPE_TRIANGLES;
            pg->surface_scale_factor = 1;
            pg->surface_shape = (SurfaceShape){ .zeta_format = 1,
                                                .color_format = 8,
                                                .clip_width = 8,
                                                .clip_height = 8 };
            pg->surface_binding_dim.width = pg->surface_binding_dim.height = 8;
            pg->material_alpha = 1;
            for (unsigned i = 0; i < 4; i++) {
                float one = 1;
                memcpy(&pg->vsh_constants[NV_IGRAPH_XF_XFCTX_CMAT0 + i][i],
                       &one, 4);
            }
            if (programmable) {
                pg->regs_[NV_PGRAPH_CSV0_D] =
                    2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
                for (unsigned i = 0; i < 2; i++) {
                    unsigned attr = i ? 3 : 0;
                    uint32_t *t = pg->program_data[i];
                    t[1] = 1 << 21 | attr << 9 | 27;
                    t[2] = 2u << 26;
                    t[3] = 1 << 11 | attr << 3 | 15 << 12 | i;
                }
            }
            pg->regs_[NV_PGRAPH_CONTROL_0] =
                NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE;
            pg->regs_[NV_PGRAPH_CONTROL_3] = NV_PGRAPH_CONTROL_3_SHADEMODE;
            pg->regs_[NV_PGRAPH_COMBINESPECFOG0] = PS_REGISTER_V0;
            pg->regs_[NV_PGRAPH_COMBINESPECFOG1] =
                (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
            float zmax = 65535;
            memcpy(&pg->regs_[NV_PGRAPH_ZCLIPMAX], &zmax, 4);
            pg->regs_[NV_PGRAPH_WINDOWCLIPX0] =
                pg->regs_[NV_PGRAPH_WINDOWCLIPY0] = 7 << 16;
            for (unsigned i = 1; i < 8; i++)
                pg->regs_[NV_PGRAPH_WINDOWCLIPX0 + i * 4] =
                    pg->regs_[NV_PGRAPH_WINDOWCLIPY0 + i * 4] = 1;
            NV2AMetalPGRAPHVertexState *vs =
                [[NV2AMetalPGRAPHVertexState alloc] initWithState:pg
                                                            error:&error];
            NV2AMetalPGRAPHPixelState *ps =
                [[NV2AMetalPGRAPHPixelState alloc] initWithState:pg
                                                        textures:nil
                                                          device:commands.device
                                                           error:&error];
            require(vs && ps, error);
            memset(pg, 0, sizeof(*pg));
            require([commands beginWithError:&error] != nil, error);
            NV2AMetalPGRAPHVertexResult *r =
                [vs encodeAttributes:batches[0].fetch.attributes
                               count:3
                             program:program
                               fixed:fixed
                            commands:commands
                               error:&error];
            require(r != nil, error);
            NV2AMetalGeometryResult *g =
                [geometry encodeVertices:r.vertices
                                   count:3
                               primitive:NV2AMetalPrimitiveTriangles
                                 polygon:NV2AMetalPolygonFill
                                  smooth:vs.smooth
                          firstProvoking:YES
                            zPerspective:vs.zPerspective
                                commands:commands
                                   error:&error];
            require(g != nil, error);
            MTLTextureDescriptor *d = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                             width:8
                                            height:8
                                         mipmapped:NO];
            d.storageMode = MTLStorageModeShared;
            d.usage = MTLTextureUsageRenderTarget;
            id<MTLTexture> target =
                [commands.device newTextureWithDescriptor:d];
            assert(target);
            MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
            pass.colorAttachments[0].texture = target;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            NV2AMetalPixelUniforms u = ps.uniforms;
            NV2AMetalPixelTexture textures[4] = { 0 };
            require([ps copyTextureBindings:textures error:&error], error);
            require([pixel encodeVertices:g.vertices
                                    count:g.vertexCount
                                primitive:g.primitiveType
                                 uniforms:&u
                                 textures:textures
                                     pass:pass
                                drawState:ps.raster
                                 commands:commands
                                    error:&error],
                    error);
            require([commands submitWithError:&error], error);
            require([commands waitUntilIdleWithError:&error], error);
            const NV2AMetalProgramOutput *raw = r.registers.contents;
            for (unsigned i = 0; i < 3; i++)
                assert(!raw[i].fault);
            float color[4];
            [target getBytes:color
                 bytesPerRow:16
                  fromRegion:MTLRegionMake2D(1, 1, 1, 1)
                 mipmapLevel:0];
            assert(color[0] == 0 && color[1] == 1 && color[2] == 0 &&
                   color[3] == 1);
            [target getBytes:color
                 bytesPerRow:16
                  fromRegion:MTLRegionMake2D(7, 7, 1, 1)
                 mipmapLevel:0];
            assert(color[0] == 1 && color[1] == 0);
            chains++;
        }
    }
}
static void rejection_and_empty_tests(void)
{
    NSError *error = nil;
    for (unsigned i = 0; i < 6; i++) {
        dma_stream();
        PGRAPHState *pg = &state->pgraph;
        pg->draw_arrays_length = 1;
        pg->draw_arrays_count[0] = 6;
        switch (i) {
        case 0:
            dma_a.limit = 158;
            break;
        case 1:
            dma_b.dma_class = 0;
            break;
        case 2:
            pg->draw_arrays_start[0] = -1;
            break;
        case 3:
            pg->inline_elements_length = 1;
            break;
        case 4:
            pg->draw_arrays_length = 1251;
            break;
        case 5:
            pg->vertex_attributes[0].format = UINT32_MAX;
            break;
        }
        float saved = pg->vertex_attributes[0].inline_value[0];
        assert(![adapter prepareWithError:&error] &&
               !surfaces.commands.commandBuffer);
        assert(pg->vertex_attributes[0].inline_value[0] == saved);
    }
    reset();
    assert(!prepare().count);
    state->pgraph.inline_array_length = 1;
    assert(![adapter prepareWithError:&error]);
    [adapter close];
    [adapter close];
    assert(![adapter prepareWithError:&error]);
    groups++;
}
/* Independent GPU Current oracle. Preserve the caller's complete input state
 * so the following host-capture case starts from the exact same metadata. */
static NSArray<NV2AMetalPGRAPHFetchBatch *> *
current_gpu_reference(NSArray<NSNumber *> *prefixes,
                      NV2AMetalPendingInput *input)
{
    NSError *error = nil;
    VertexAttribute saved[16];
    memcpy(saved, state->pgraph.vertex_attributes, sizeof(saved));
    uint16_t compressed = state->pgraph.compressed_attrs;
    NSArray *batches = [adapter encodeIndependentSnapshotsWithPrefixes:prefixes
                                                          indexedInput:input
                                                                 error:&error];
    require(batches != nil && [adapter completeWithError:&error], error);
    memcpy(state->pgraph.vertex_attributes, saved, sizeof(saved));
    state->pgraph.compressed_attrs = compressed;
    return batches;
}
static void check_captured_fetch(NSArray<NV2AMetalPGRAPHFetchBatch *> *batches)
{
    for (NV2AMetalPGRAPHFetchBatch *batch in batches) {
        NV2AMetalFetchResult *result = batch.fetch;
        assert(!result.hasCurrent);
        assert(result.attributes.length ==
               result.vertexCount * sizeof(NV2AMetalProgramInput));
        assert(result.faults.length ==
               (result.vertexCount ? result.vertexCount + 1 : 0) * 4);
        if (!result.vertexCount)
            assert(!result.attributes && !result.faults);
    }
}
#include "test-metal-fetch-independent.h"
#include "test-metal-fetch-dirty-source.h"
#include "test-metal-pgraph-fetch-suffix.h"
#include "test-metal-inline-current.h"
#include "test-metal-packed-float-current.h"
#include "test-metal-packed-current.h"
#include "test-metal-dma-current.h"
#include "test-metal-current-guard.h"
#include "test-metal-fetch-prefix-reads.h"
#include "test-metal-fetch-sparse-reads.h"
int main(int argc, char **argv)
{
    @autoreleasepool {
        NSError *error = nil;
        state = g_new0(NV2AState, 1);
        state->vram = g_new0(MemoryRegion, 1);
        assert(
            !posix_memalign((void **)&state->vram_ptr, getpagesize(), 65536));
        memset(state->vram_ptr, 0, 65536);
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        id<MTLBuffer> vram = [commands.device
            newBufferWithBytesNoCopy:state->vram_ptr
                              length:65536
                             options:MTLResourceStorageModeShared
                         deallocator:nil];
        assert(vram);
        surfaces = [[NV2AMetalSurfaceCache alloc]
            initWithCommands:commands
                        vram:vram
                didWriteVRAM:^(NSUInteger address, NSUInteger length) {
                  assert(((address == 12288 || address == 16896) &&
                          length == 64) ||
                         (address == 65520 && length == 16));
                  notifications++;
                }
                       error:&error];
        require(surfaces != nil, error);
        adapter = [[NV2AMetalPGRAPHFetch alloc] initWithState:state
                                                     surfaces:surfaces
                                                        error:&error];
        require(adapter != nil, error);
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--current-guard")))
            current_guard_tests();
        if (argc == 2 && !strcmp(argv[1], "--current-guard"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--sparse-reads")))
            fetch_sparse_read_tests();
        if (argc == 2 && !strcmp(argv[1], "--sparse-reads"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--prefix-reads"))) {
            fetch_prefix_read_tests();
            current_only_source_tests();
        }
        if (argc == 2 && !strcmp(argv[1], "--prefix-reads"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--captured-current")))
            captured_current_completion_tests();
        if (argc == 2 && !strcmp(argv[1], "--captured-current"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--dma-current"))) {
            dma_current_tests();
            dma_current_guard_tests();
        }
        if (argc == 2 && !strcmp(argv[1], "--dma-current"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--packed-current")))
            packed_current_tests();
        if (argc == 2 && !strcmp(argv[1], "--packed-current"))
            goto close;
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--packed-float-current")))
            packed_float_current_tests();
        if (argc == 2 && !strcmp(argv[1], "--packed-float-current"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--inline-current")))
            inline_current_tests();
        if (argc == 2 && !strcmp(argv[1], "--inline-current"))
            goto close;
        if (argc == 2 && !strcmp(argv[1], "--suffix")) {
            pgraph_fetch_suffix_tests();
            goto close;
        }
        if (argc == 2 && !strcmp(argv[1], "--dirty-source")) {
            fetch_dirty_source_tests();
            goto close;
        }
        independent_snapshot_tests();
        if (argc == 2 && !strcmp(argv[1], "--independent-snapshots"))
            goto close;
        assert(argc == 1);
        pgraph_fetch_suffix_tests();
        fetch_dirty_source_tests();
        idx_normalized_paths();
        current_publication_tests();
        submitted_current_tests();
        array_and_index_tests();
        packed_and_inline_buffer_tests();
        packed_normal_and_overlap_tests();
        gpu_alias_and_last_page_tests();
        bounded_core_test();
        full_chain_tests();
        rejection_and_empty_tests();
    close:
        require([surfaces flushWithError:&error], error);
        adapter = nil;
        surfaces = nil;
        vram = nil;
        commands = nil;
        free(state->vram_ptr);
        g_free(state->vram);
        g_free(state);
        printf(
            "Metal 4 PGRAPH fetch: %u DMA/inline/index/current-value groups, "
            "%u full GPU chains PASS\n",
            groups, chains);
    }
    return 0;
}
