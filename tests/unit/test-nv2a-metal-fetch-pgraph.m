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
#import "hw/xbox/nv2a/pgraph/metal/vertex-writable.h"
#include "test-metal-vertex-context.h"
#include <time.h>

#include "test-metal-idx.h"

static NV2AState *state;
static NV2AMetalSurfaceCache *surfaces;
static NV2AMetalPGRAPHFetch *adapter;
static DMAObject dma_a, dma_b;
static unsigned dma_loads;
static bool dirty_last;
static unsigned groups, reads, dirty_read_pages, notifications;
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
    dma_loads++;
    return object == 16 ? dma_a : dma_b;
}
bool memory_region_test_and_clear_dirty(MemoryRegion *mr, hwaddr address,
                                        hwaddr length, unsigned client)
{
    assert(mr == state->vram && client == DIRTY_MEMORY_NV2A && length &&
           address <= 65536 && length <= 65536 - address);
    reads++;
    for (hwaddr page = address / 4096;
         page <= (address + length - 1) / 4096; page++)
        dirty_read_pages |= 1u << page;
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
    assert(!b.fetch.faultSummaryOffset && b.fetch.faults.length == 4 &&
           !*(const uint32_t *)b.fetch.faults.contents);
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
            *(uint32_t *)b[batch].fetch.faults.contents =
                failure == 3 ? UINT32_MAX : 1;
            assert(![adapter completeWithError:&error] && error);
            assert([error.localizedDescription containsString:@"vertex fetch"]);
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
    puts("Metal4 fused Current publication: cancel, first/later/overflow fault, "
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
            *(uint32_t *)b[0].fetch.faults.contents = 1u << (failure - 1);
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
         "recording preserved;duplicate submit rejected;fetch faults "
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
        assert(!result.faultSummaryOffset &&
               result.faults.length == (result.vertexCount ? 4 : 0));
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
#include "test-metal-fetch-readonly-dedupe.h"

/* The cache owns range metadata, never VRAM readiness or index snapshots. */
static NSData *index_ranges_reference(const uint32_t *indices, NSUInteger count)
{
    NSMutableIndexSet *set = [NSMutableIndexSet new];
    for (NSUInteger i = 0; i < count; i++)
        [set addIndex:indices[i]];
    NSMutableData *result = [NSMutableData new];
    [set enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
      (void)stop;
      [result appendBytes:&range length:sizeof(range)];
    }];
    return result;
}

static NSData *index_ranges_run(NV2AMetalPGRAPHFetch *owner,
                                NV2AMetalPendingInput *input, NSUInteger prefix,
                                BOOL host)
{
    NSError *error = nil;
    NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
        host ? [owner encodeCurrentSnapshotsWithPrefixes:@[ @(prefix) ]
                                            indexedInput:input
                                                   error:&error] :
               [owner encodeIndependentSnapshotsWithPrefixes:@[ @(prefix) ]
                                                indexedInput:input
                                                       error:&error];
    require(batches != nil, error);
    if (state->pgraph.vertex_attributes[0].count &&
        !state->pgraph.vertex_attributes[0].stride) {
        BOOL completed = YES;
        require([surfaces tryIdleCPUAccessAtAddress:dma_a.address +
                    state->pgraph.vertex_attributes[0].offset
            length:16 write:YES completed:&completed error:&error], error);
        assert(!completed);
    }
    if (host) {
        require([owner completeCurrentSnapshotsWithError:&error] &&
                    [surfaces submitWithError:&error] &&
                    [surfaces waitUntilIdleWithError:&error],
                error);
    } else {
        require([owner completeWithError:&error], error);
    }
    PGRAPHState *pg = &state->pgraph;
    const uint32_t *indices = input ? input.indices.bytes : pg->inline_elements;
    NSUInteger count = pg->inline_elements_length;
    assert(batches.count == 1 && batches[0].inputVertexCount == count &&
           batches[0].firstDecodedVertex == prefix &&
           batches[0].fetch.vertexCount == count - prefix);
    if (prefix < count) {
        const NV2AMetalProgramInput *actual = values(batches[0]);
        for (NSUInteger i = prefix; i < count; i++)
            assert(!memcmp(actual[i - prefix].attributes[0],
                           state->vram_ptr + dma_a.address +
                               pg->vertex_attributes[0].offset +
                               indices[i] * pg->vertex_attributes[0].stride,
                           16));
    }
    assert(!memcmp(pg->vertex_attributes[0].inline_value,
                   state->vram_ptr + dma_a.address +
                       pg->vertex_attributes[0].offset +
                       indices[count - 1] * pg->vertex_attributes[0].stride,
                   16));
    NSData *cached = [owner valueForKey:@"indexRanges"];
    BOOL needsIndexRanges = NO;
    for (unsigned i = 0; i < 16 && !needsIndexRanges; i++)
        needsIndexRanges = pg->vertex_attributes[i].count &&
                           pg->vertex_attributes[i].stride;
    if (cached && needsIndexRanges) {
        /* The TCG read plan protects the selected Current vertex even
         * when the entire decoded suffix is already accepted. */
        NSUInteger firstRead = tcg_allowed ? MIN(prefix, count - 1) : prefix;
        assert([owner valueForKey:@"indexRangesInput"] == input &&
               [[owner valueForKey:@"indexRangesPrefix"]
                   unsignedIntegerValue] == prefix &&
               cached.length + [[owner valueForKey:@"indexRangesKey"] length] <=
                   65536 &&
               ![cached isKindOfClass:NSMutableData.class] &&
               [cached isEqualToData:index_ranges_reference(indices + firstRead,
                                                            count - firstRead)]);
    }
    groups++;
    return needsIndexRanges ? cached : nil;
}

static NV2AMetalCachedSurface *index_ranges_writer(NSUInteger index)
{
    NSError *error = nil;
    NV2AMetalSurfaceConfig config = {
        .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        .width = 4,
        .height = 1,
        .pitch = 16,
        .scale = 1,
        .color = YES
    };
    NV2AMetalCachedSurface *dirty =
        [surfaces prepareSurfaceAtAddress:dma_a.address + index * 16
                                   config:&config
                                    frame:0
                                    error:&error];
    NV2AMetalClear *clear =
        [[NV2AMetalClear alloc] initWithDevice:surfaces.commands.device
                                         error:&error];
    NV2AMetalClearConfig c = { .parameter = NV097_CLEAR_SURFACE_COLOR,
                               .rect = { 0, 0, 4, 1 } };
    require(dirty && clear &&
                [clear encodeColor:dirty.transfer.texture
                              zeta:nil
                            config:&c
                          commands:surfaces.commands
                             error:&error] &&
                [surfaces markWritten:dirty error:&error] &&
                [surfaces checkpointWithError:&error],
            error);
    return dirty;
}

static void index_ranges_benchmark(BOOL zeroStride, BOOL changing)
{
    NSError *error = nil;
    require([surfaces discardForRestoreWithError:&error], error);
    reset();
    NV2AMetalPGRAPHFetch *owner = [[NV2AMetalPGRAPHFetch alloc]
        initWithState:state surfaces:surfaces error:&error];
    require(owner != nil, error);
    PGRAPHState *pg = &state->pgraph;
    pg->vertex_attributes[0] = (VertexAttribute){
        .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        .size = 4, .count = 4, .stride = zeroStride ? 0 : 16
    };
    const float source[4] = { 17, .25f, -2, 1 };
    cpu_write(dma_a.address, 1024 * sizeof(source));
    for (unsigned i = 0; i < 1024; i++)
        memcpy(state->vram_ptr + dma_a.address + i * sizeof(source),
               source, sizeof(source));
    unsigned count = zeroStride ? 65536 : 16000;
    pg->inline_elements_length = count;
    for (unsigned i = 0; i < count; i++)
        pg->inline_elements[i] = (i * 25173 + 1) % 1024;
    double seconds = 0;
    for (unsigned iteration = 0; iteration < 44; iteration++) {
        @autoreleasepool {
            if (changing)
                for (unsigned i = 0; i < count; i++)
                    pg->inline_elements[i] = (i * 25173 + iteration * 13 + 1) % 1024;
            NV2AMetalPendingInput *input = [NV2AMetalPendingInput
                indexedBytes:pg->inline_elements count:count matchingPrevious:nil];
            assert(input);
            struct timespec start, finish;
            assert(!clock_gettime(CLOCK_MONOTONIC, &start));
            NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
                [owner encodeIndependentSnapshotsWithPrefixes:@[ @0 ]
                    indexedInput:input error:&error];
            assert(!clock_gettime(CLOCK_MONOTONIC, &finish));
            require(batches != nil, error);
            if (iteration >= 4)
                seconds += finish.tv_sec - start.tv_sec +
                           (finish.tv_nsec - start.tv_nsec) * 1e-9;
            require([owner completeWithError:&error], error);
            const NV2AMetalProgramInput *actual = values(batches[0]);
            assert(batches[0].fetch.vertexCount == count &&
                   !memcmp(actual[0].attributes[0], source, sizeof(source)) &&
                   !memcmp(actual[count - 1].attributes[0], source, sizeof(source)) &&
                   !memcmp(pg->vertex_attributes[0].inline_value, source,
                           sizeof(source)));
        }
    }
    [owner close];
    printf("Index plan encoding CPU benchmark: 40 fresh-descriptor encodes, "
           "%u unsorted dense indices stride%u changing%u %.3f ms PASS; excludes descriptor "
           "creation and completion waits, no guest/GPU timing\n",
           count, pg->vertex_attributes[0].stride, (unsigned)changing, seconds * 1000);
}

static void index_range_word_tests(void)
{
    NSError *error = nil;
    require([surfaces discardForRestoreWithError:&error], error);
    reset();
    NV2AMetalPGRAPHFetch *owner = [[NV2AMetalPGRAPHFetch alloc]
        initWithState:state surfaces:surfaces error:&error];
    require(owner != nil, error);
    PGRAPHState *pg = &state->pgraph;
    pg->vertex_attributes[0] = (VertexAttribute){
        .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        .size = 4, .count = 4, .stride = 1
    };
    unsigned cases = 0;
    for (unsigned shape = 0; shape < 8; shape++) {
        uint32_t words[129];
        unsigned count = 129;
        if (shape <= 1)
            for (unsigned i = 0; i < count; i++)
                words[i] = UINT32_MAX - 128 + (i * (shape ? 17 : 37)) % 129;
        if (shape == 2 || shape == 3) {
            const unsigned offsets[] = { 128, 64, 0, 63, 127, 65 };
            count = shape == 2 ? 5 : 6;
            for (unsigned i = 0; i < count; i++)
                words[i] = 0x80000000u + offsets[i];
        }
        if (shape == 4) {
            const uint32_t wide[] = { UINT32_MAX, 0, 0x80000000u,
                                      0x7fffffffu, UINT32_MAX, 1 };
            count = ARRAY_SIZE(wide);
            memcpy(words, wide, sizeof(wide));
        }
        if (shape >= 5)
            for (unsigned i = 0; i < count; i++)
                words[i] = shape == 5 ? UINT32_MAX :
                           shape == 6 ? 0x80000000u + i : UINT32_MAX - i;
        pg->inline_elements_length = count;
        memcpy(pg->inline_elements, words, count * sizeof(*words));
        NV2AMetalPendingInput *input = [NV2AMetalPendingInput
            indexedBytes:words count:count matchingPrevious:nil];
        assert(input);
        const NSUInteger prefixes[] = { 0, count / 2, count - 1, count };
        for (unsigned hooked = 0; hooked < 2; hooked++)
            for (unsigned p = 0; p < ARRAY_SIZE(prefixes); p++) {
                tcg_allowed = hooked;
                error = nil;
                VertexAttribute saved[16];
                memcpy(saved, pg->vertex_attributes, sizeof(saved));
                pg->compressed_attrs = 0x40;
                assert(![owner encodeIndependentSnapshotsWithPrefixes:@[ @(prefixes[p]) ]
                    indexedInput:input error:&error] && error &&
                    !memcmp(saved, pg->vertex_attributes, sizeof(saved)) &&
                    pg->compressed_attrs == 0x40 && !surfaces.recording);
                NSUInteger first = hooked ? MIN(prefixes[p], count - 1) : prefixes[p];
                NSData *actual = [owner valueForKey:@"indexRanges"];
                assert(actual && [actual isEqualToData:
                    index_ranges_reference(words + first, count - first)]);
                cases++;
            }
    }
    tcg_allowed = true;
    [owner close];
    printf("Index range word boundaries: %u bitmap/sort/sorted cases, "
           "word edges,duplicates,UINT32_MAX,wide domains,exact scratch-budget "
           "boundary and Current prefixes match an independent index set; "
           "invalid DMA keeps Current unchanged and prevents GPU dispatch PASS\n", cases);
}

static void index_range_radix_tests(void)
{
    NSError *error = nil;
    require([surfaces discardForRestoreWithError:&error], error);
    reset();
    NV2AMetalPGRAPHFetch *owner = [[NV2AMetalPGRAPHFetch alloc]
        initWithState:state surfaces:surfaces error:&error];
    require(owner != nil, error);
    PGRAPHState *pg = &state->pgraph;
    pg->vertex_attributes[0] = (VertexAttribute){
        .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        .size = 4, .count = 4, .stride = 1
    };
    const unsigned lengths[] = { 64, 65, 129, 257, 4096, 65536,
                                 NV2A_MAX_BATCH_LENGTH };
    unsigned cases = 0;
    for (unsigned shape = 0; shape < 6; shape++)
        for (unsigned n = 0; n < ARRAY_SIZE(lengths); n++) {
            unsigned count = lengths[n];
            NSMutableData *words = [NSMutableData dataWithLength:count * 4];
            uint32_t *indices = words.mutableBytes;
            for (unsigned i = 0; i < count; i++) {
                uint32_t v = (i * 25173 + 1) % MIN(count, 2048u);
                switch (shape) {
                case 0: indices[i] = v * 2654435761u; break;
                case 1: indices[i] = 0x80000000u | v * 4093; break;
                case 2: indices[i] = 0xffffff00u | (v & 255); break;
                case 3: indices[i] = (v & 1) ? v : UINT32_MAX - v; break;
                case 4: indices[i] = v * 256 + 0x7ff00000u; break;
                case 5: indices[i] = 0xff000000u | v * 8179; break;
                }
            }
            /* Keep the global domain sparse even with many duplicates;
             * shapes 1/2/4 still drive a large shared-byte bucket deeper. */
            indices[0] = UINT32_MAX;
            indices[count - 1] = 0;
            pg->inline_elements_length = count;
            memcpy(pg->inline_elements, indices, words.length);
            NV2AMetalPendingInput *input = [NV2AMetalPendingInput
                indexedBytes:indices count:count matchingPrevious:nil];
            assert(input);
            NSData *original = [input.indices copy];
            const NSUInteger prefixes[] = { 0, count / 2, count - 1, count };
            for (unsigned hooked = 0; hooked < 2; hooked++)
                for (unsigned p = 0; p < ARRAY_SIZE(prefixes); p++) {
                    tcg_allowed = hooked;
                    error = nil;
                    VertexAttribute saved[16];
                    memcpy(saved, pg->vertex_attributes, sizeof(saved));
                    pg->compressed_attrs = 0x40;
                    assert(![owner encodeIndependentSnapshotsWithPrefixes:@[ @(prefixes[p]) ]
                        indexedInput:input error:&error] && error &&
                        !memcmp(saved, pg->vertex_attributes, sizeof(saved)) &&
                        pg->compressed_attrs == 0x40 && !surfaces.recording &&
                        !memcmp(pg->inline_elements, indices, words.length) &&
                        [input.indices isEqualToData:original]);
                    NSUInteger first = hooked ? MIN(prefixes[p], count - 1) : prefixes[p];
                    NSData *actual = [owner valueForKey:@"indexRanges"];
                    assert(actual && [actual isEqualToData:
                        index_ranges_reference(indices + first, count - first)]);
                    cases++;
                }
        }
    tcg_allowed = true;
    [owner close];
    printf("Index range radix: %u independent index-set comparisons, "
           "64/65 boundary, all four bytes, shared-byte buckets, duplicates, "
           "UINT32_MAX and maximum batch; input and Current unchanged, "
           "invalid DMA prevents GPU dispatch PASS\n", cases);
    require([surfaces discardForRestoreWithError:&error], error);
    reset();
    owner = [[NV2AMetalPGRAPHFetch alloc]
        initWithState:state surfaces:surfaces error:&error];
    require(owner != nil, error);
    pg->vertex_attributes[0] = (VertexAttribute){
        .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        .size = 4, .count = 4, .stride = 16
    };
    cpu_write(dma_a.address, 3968 * 16);
    for (unsigned i = 0; i < 3968; i++)
        for (unsigned lane = 0; lane < 4; lane++) {
            float value = i * 10 + lane + .25f;
            memcpy(state->vram_ptr + dma_a.address + i * 16 + lane * 4,
                   &value, 4);
        }
    const NSUInteger prefixes[] = { 0, 1, 32, 65 };
    cases = 0;
    for (unsigned hooked = 0; hooked < 2; hooked++)
        for (unsigned host = 0; host < 2; host++)
            for (unsigned p = 0; p < ARRAY_SIZE(prefixes); p++) {
                tcg_allowed = hooked;
                pg->inline_elements_length = 65;
                for (unsigned i = 0; i < 65; i++)
                    pg->inline_elements[i] = (i * 2377 + p * 11) % 3968;
                pg->inline_elements[0] = 3967;
                pg->inline_elements[64] = 0;
                NV2AMetalPendingInput *input = [NV2AMetalPendingInput
                    indexedBytes:pg->inline_elements count:65 matchingPrevious:nil];
                assert(input && index_ranges_run(owner, input, prefixes[p], host));
                cases++;
            }
    tcg_allowed = true;
    [owner close];
    printf("Index range radix GPU: %u host/GPU Current,TCG/fallback,"
           "full/suffix cases across the 64/65 cutoff; exact attributes,"
           "Current and independent range reference PASS\n", cases);
}

static void index_ranges_wide_benchmark(void)
{
    NSError *error = nil;
    require([surfaces discardForRestoreWithError:&error], error);
    reset();
    NV2AMetalPGRAPHFetch *owner = [[NV2AMetalPGRAPHFetch alloc]
        initWithState:state surfaces:surfaces error:&error];
    require(owner != nil, error);
    PGRAPHState *pg = &state->pgraph;
    pg->vertex_attributes[0] = (VertexAttribute){
        .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        .size = 4, .count = 4, .stride = 1
    };
    const unsigned count = 65536;
    pg->inline_elements_length = count;
    double seconds = 0;
    for (unsigned iteration = 0; iteration < 44; iteration++) {
        @autoreleasepool {
            for (unsigned i = 0; i < count; i++)
                pg->inline_elements[i] = (i + iteration * 13) * 2654435761u;
            pg->inline_elements[0] = UINT32_MAX;
            NV2AMetalPendingInput *input = [NV2AMetalPendingInput
                indexedBytes:pg->inline_elements count:count matchingPrevious:nil];
            assert(input);
            struct timespec start, finish;
            error = nil;
            assert(!clock_gettime(CLOCK_MONOTONIC, &start));
            NSArray *batches = [owner encodeIndependentSnapshotsWithPrefixes:@[ @0 ]
                indexedInput:input error:&error];
            assert(!clock_gettime(CLOCK_MONOTONIC, &finish));
            assert(!batches && error && !surfaces.recording &&
                   ![owner valueForKey:@"indexRanges"] &&
                   !memcmp(pg->inline_elements, input.indices.bytes, count * 4));
            if (iteration >= 4)
                seconds += finish.tv_sec - start.tv_sec +
                           (finish.tv_nsec - start.tv_nsec) * 1e-9;
        }
    }
    [owner close];
    printf("Index wide plan CPU benchmark: 40 fresh-descriptor plans, "
           "65536 sparse uint32 indices %.3f ms PASS; invalid DMA after "
           "range construction, no GPU dispatch or guest timing\n", seconds * 1000);
}

static NV2AMetalValidatedProgram *constant_read_program(NSError **error)
{
    Token tokens[3];
    tokens[0] = token(NV2AMetalMACMov, 0, 96);
    source(&tokens[0], 0, 2, 0, 0xe4);
    destination(&tokens[0], 0x100, 15, 0, 0, 0, 0);
    tokens[1] = token(NV2AMetalMACArl, 0, 96);
    tokens[1].word[1] |= 3u << 9;
    source(&tokens[1], 0, 2, 0, 0);
    destination(&tokens[1], 0, 0, 0, 0, 0, 0);
    tokens[2] = token(NV2AMetalMACMov, 0, 96);
    source(&tokens[2], 0, 3, 0, 0xe4);
    destination(&tokens[2], 0x103, 15, 0, 0, 0, 0);
    tokens[2].word[3] |= 3;
    return [[NV2AMetalValidatedProgram alloc]
        initWithTokens:tokens[0].word length:3 error:error];
}

static void constant_float_proof_tests(void)
{
    NSError *error = nil;
    NV2AMetalCommands *commands = surfaces.commands;
    NV2AMetalWritableProgram *engine = [[NV2AMetalWritableProgram alloc]
        initWithDevice:commands.device error:&error];
    require(engine != nil, error);
    NV2AMetalValidatedProgram *program = constant_read_program(&error);
    require(program != nil, error);
    NV2AMetalProgramUniforms u = { 0 };
    u.surface_size[0] = u.surface_size[1] = 8;
    u.zmax = 65535;
    u.point_scale = u.point_size = 1;
    u.constants[97][1] = u.constants[97][3] = 1;
    const float data[4] = { 1.25f, -0.5f, 0.25f, 2 };
    unsigned cases = 0;
    for (unsigned hostSeed = 0; hostSeed < 2; hostSeed++)
        for (unsigned components = 1; components <= 4; components++)
            for (unsigned indexed = 0; indexed < 2; indexed++)
                for (unsigned access = 0; access < 2; access++) {
                    require([surfaces discardForRestoreWithError:&error], error);
                    reset();
                    PGRAPHState *pg = &state->pgraph;
                    NV2AMetalPGRAPHFetch *owner = [[NV2AMetalPGRAPHFetch alloc]
                        initWithState:state surfaces:surfaces error:&error];
                    require(owner != nil, error);
                    pg->vertex_attributes[3] = (VertexAttribute){
                        .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                        .size = 4, .count = components, .stride = 0
                    };
                    cpu_write(dma_a.address, sizeof(data));
                    memcpy(state->vram_ptr + dma_a.address, data, sizeof(data));
                    if (indexed) {
                        pg->inline_elements_length = 3;
                        const uint32_t indices[] = { UINT32_MAX, 4, 2 };
                        memcpy(pg->inline_elements, indices, sizeof(indices));
                    } else {
                        pg->draw_arrays_length = 1;
                        pg->draw_arrays_start[0] = 2;
                        pg->draw_arrays_count[0] = 3;
                    }
                    NV2AMetalFetchUniforms preview;
                    [owner getSourcePreview:&preview attributes:1u << 3];
                    assert(preview.attributes[3].count == components);
                    NSArray<NV2AMetalPGRAPHFetchBatch *> *seed = hostSeed ?
                        [owner encodeCurrentSnapshotsWithPrefixes:@[ @0 ] indexedInput:nil error:&error] :
                        [owner encodeIndependentSnapshotsWithError:&error];
                    require(seed != nil, error);
                    require(hostSeed ? [owner completeCurrentSnapshotsWithError:&error] :
                                       [owner completeWithError:&error], error);
                    if (hostSeed)
                        require([surfaces submitWithError:&error] &&
                                [surfaces waitUntilIdleWithError:&error], error);
                    float expected[4] = { 0, 0, 0, 1 };
                    memcpy(expected, data, components * 4);
                    [owner getSourcePreview:&preview attributes:1u << 3];
                    assert(!preview.attributes[3].count &&
                           !memcmp(preview.attributes[3].inline_value, expected, 16) &&
                           [program hasFaultFreeReadOnlyAccess:access constants:&u.constants[0][0]
                                               sourceUniforms:&preview]);
                    NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
                        [owner encodeCurrentSnapshotsWithPrefixes:@[ @0 ] indexedInput:nil error:&error];
                    require(batches != nil && batches.count == 1, error);
                    NV2AMetalFetchResult *f = batches[0].fetch;
                    NV2AMetalFetchUniforms proof, raw;
                    assert([f getSourceUniforms:&raw attributeBuffer:f.attributes
                             first:0 count:3 commands:commands] &&
                           [f getReadonlyProofUniforms:&proof attributeBuffer:f.attributes
                             first:0 count:3 commands:commands] &&
                           raw.attributes[3].count == components &&
                           !proof.attributes[3].count &&
                           !memcmp(proof.attributes[3].inline_value, expected, 16));
                    assert(![f getReadonlyProofUniforms:&proof attributeBuffer:seed[0].fetch.attributes
                              first:0 count:3 commands:commands] &&
                           ![f getReadonlyProofUniforms:&proof attributeBuffer:f.attributes
                              first:2 count:2 commands:commands]);
                    NV2AMetalWritableEncoding *candidate = [engine encodeProgram:program
                        uniforms:&u attributeBuffer:f.attributes first:0 count:3 access:access
                        writeEnable:NO rasterize:YES compactRegisters:YES attributeFetch:f
                        commands:commands error:&error];
                    NV2AMetalWritableEncoding *reference = [engine encodeProgram:program
                        uniforms:&u attributeBuffer:f.attributes first:0 count:3 access:access
                        writeEnable:NO rasterize:YES compactRegisters:NO
                        commands:commands error:&error];
                    require(candidate && reference, error);
                    assert([candidate canUsePendingReadOnlyResultForCommands:commands]);
                    require([owner completeCurrentSnapshotsWithError:&error] &&
                            [surfaces submitWithError:&error] &&
                            [surfaces waitUntilIdleWithError:&error], error);
                    NV2AMetalWritableResult *actual = [candidate resolveWithError:&error];
                    NV2AMetalWritableResult *golden = [reference resolveWithError:&error];
                    require(actual && golden, error);
                    assert(actual.vertexCount == 3 && golden.vertexCount == 3 &&
                           actual.vertices.length == golden.vertices.length &&
                           !memcmp(actual.vertices.contents, golden.vertices.contents, actual.vertices.length) &&
                           !memcmp(pg->vertex_attributes[3].inline_value, expected, 16) &&
                           ![f getReadonlyProofUniforms:&proof attributeBuffer:f.attributes
                               first:0 count:3 commands:commands]);
                    /* A changed mapping or format cannot borrow the old source value. */
                    pg->vertex_attributes[3].offset = 16;
                    [owner getSourcePreview:&preview attributes:1u << 3];
                    assert(preview.attributes[3].count == components);
                    pg->vertex_attributes[3].offset = 0;
                    pg->vertex_attributes[3].stride = 4;
                    [owner getSourcePreview:&preview attributes:1u << 3];
                    assert(preview.attributes[3].count == components);
                    pg->vertex_attributes[3].stride = 0;
                    cpu_write(dma_a.address, components * 4);
                    [owner getSourcePreview:&preview attributes:1u << 3];
                    assert(preview.attributes[3].count == components);
                    [owner close];
                    cases++;
                }
    printf("Constant Float proof: %u host/GPU-seeded,array/indexed,component/USER-FULL "
           "cases; bound no-wait admission matches generic GPU vertices,exact Current,"
           "raw uniforms intact,mapping/stride/write/recording invalidation PASS\n", cases);
    const uint32_t changed[] = { 0x7fc12345u, 0x447a0000u, 0xbf800000u };
    cases = 0;
    for (unsigned value = 0; value < ARRAY_SIZE(changed); value++)
        for (unsigned access = 0; access < 2; access++) {
            require([surfaces discardForRestoreWithError:&error], error);
            reset();
            PGRAPHState *pg = &state->pgraph;
            NV2AMetalPGRAPHFetch *owner = [[NV2AMetalPGRAPHFetch alloc]
                initWithState:state surfaces:surfaces error:&error];
            require(owner != nil, error);
            pg->draw_arrays_length = 1;
            pg->draw_arrays_count[0] = 3;
            pg->vertex_attributes[3] = (VertexAttribute){
                .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                .size = 4, .count = 4, .stride = 0
            };
            cpu_write(dma_a.address, sizeof(data));
            memcpy(state->vram_ptr + dma_a.address, data, sizeof(data));
            require([owner encodeIndependentSnapshotsWithError:&error] &&
                    [owner completeWithError:&error], error);
            NV2AMetalFetchUniforms preview;
            [owner getSourcePreview:&preview attributes:1u << 3];
            assert(!preview.attributes[3].count &&
                   [program hasFaultFreeReadOnlyAccess:access constants:&u.constants[0][0]
                                       sourceUniforms:&preview]);
            cpu_write(dma_a.address, 4);
            memcpy(state->vram_ptr + dma_a.address, &changed[value], 4);
            [owner getSourcePreview:&preview attributes:1u << 3];
            assert(preview.attributes[3].count == 4);
            NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
                [owner encodeCurrentSnapshotsWithPrefixes:@[ @0 ] indexedInput:nil error:&error];
            require(batches != nil, error);
            NV2AMetalFetchResult *f = batches[0].fetch;
            NV2AMetalWritableEncoding *candidate = [engine encodeProgram:program
                uniforms:&u attributeBuffer:f.attributes first:0 count:3 access:access
                writeEnable:NO rasterize:YES compactRegisters:YES attributeFetch:f
                commands:commands error:&error];
            NV2AMetalWritableEncoding *reference = [engine encodeProgram:program
                uniforms:&u attributeBuffer:f.attributes first:0 count:3 access:access
                writeEnable:NO rasterize:YES compactRegisters:NO
                commands:commands error:&error];
            require(candidate && reference, error);
            BOOL valid = value == 2 && access;
            assert([candidate canUsePendingReadOnlyResultForCommands:commands] == valid);
            require([owner completeCurrentSnapshotsWithError:&error] &&
                    [surfaces submitWithError:&error] &&
                    [surfaces waitUntilIdleWithError:&error], error);
            error = nil;
            NV2AMetalWritableResult *actual = [candidate resolveWithError:&error];
            assert((actual != nil) == valid && (error != nil) == !valid);
            error = nil;
            NV2AMetalWritableResult *golden = [reference resolveWithError:&error];
            assert((golden != nil) == valid && (error != nil) == !valid);
            if (valid)
                assert(actual.vertices.length == golden.vertices.length &&
                       !memcmp(actual.vertices.contents, golden.vertices.contents, actual.vertices.length));
            [owner getSourcePreview:&preview attributes:1u << 3];
            assert(!preview.attributes[3].count &&
                   [program hasFaultFreeReadOnlyAccess:access constants:&u.constants[0][0]
                                       sourceUniforms:&preview] == valid);
            [owner close];
            cases++;
        }
    error = nil;
    require([surfaces discardForRestoreWithError:&error], error);
    reset();
    PGRAPHState *pg = &state->pgraph;
    pg->draw_arrays_length = 1;
    pg->draw_arrays_count[0] = 3;
    pg->vertex_attributes[0] = (VertexAttribute){
        .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        .size = 4, .count = 4, .stride = 0
    };
    cpu_write(dma_a.address, sizeof(data));
    memcpy(state->vram_ptr + dma_a.address, data, sizeof(data));
    NV2AMetalPGRAPHFetch *owner = [[NV2AMetalPGRAPHFetch alloc]
        initWithState:state surfaces:surfaces error:&error];
    require(owner && [owner encodeIndependentSnapshotsWithError:&error] &&
            [owner completeWithError:&error], error);
    NV2AMetalFetchUniforms preview;
    [owner getSourcePreview:&preview attributes:1];
    assert(!preview.attributes[0].count);
    require([surfaces prepareGPUWriteAtAddress:dma_a.address length:16 error:&error], error);
    [owner getSourcePreview:&preview attributes:1];
    assert(preview.attributes[0].count == 4);
    [surfaces cancel];
    [owner getSourcePreview:&preview attributes:1];
    assert(!preview.attributes[0].count);
    require([surfaces prepareGPUWriteAtAddress:dma_a.address length:16 error:&error] &&
            [surfaces submitWithError:&error], error);
    [owner getSourcePreview:&preview attributes:1];
    assert(preview.attributes[0].count == 4);
    require([surfaces waitUntilIdleWithError:&error] &&
            [owner encodeIndependentSnapshotsWithError:&error] &&
            [owner completeWithError:&error], error);
    pg->vertex_attributes[0].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K;
    [owner getSourcePreview:&preview attributes:1];
    assert(preview.attributes[0].count == 4);
    pg->vertex_attributes[0].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
    dma_a.address += 16;
    [owner getSourcePreview:&preview attributes:1];
    assert(preview.attributes[0].count == 4);
    dma_a.address -= 16;
    dma_a.limit = 7;
    [owner getSourcePreview:&preview attributes:1];
    assert(preview.attributes[0].count == 4);
    dma_a.limit = 65535;
    NV2AMetalCachedSurface *dirty = index_ranges_writer(0);
    assert(dirty.dirty);
    [owner getSourcePreview:&preview attributes:1];
    assert(preview.attributes[0].count == 4);
    require([surfaces discardForRestoreWithError:&error], error);
    [owner getSourcePreview:&preview attributes:1];
    assert(preview.attributes[0].count == 4);
    require([owner encodeIndependentSnapshotsWithError:&error] &&
            [owner completeWithError:&error], error);
    NSArray<NV2AMetalPGRAPHFetchBatch *> *cancelled =
        [owner encodeCurrentSnapshotsWithPrefixes:@[ @0 ] indexedInput:nil error:&error];
    require(cancelled != nil, error);
    [owner cancel];
    assert(![cancelled[0].fetch getReadonlyProofUniforms:&preview
                attributeBuffer:cancelled[0].fetch.attributes first:0 count:3 commands:commands]);
    [owner close];
    /* A CPU write after the reader retires must not tag old GPU Current
     * with the newer version observed by the subsequent completion call. */
    owner = [[NV2AMetalPGRAPHFetch alloc] initWithState:state surfaces:surfaces error:&error];
    require(owner && [owner encodeIndependentSnapshotsWithError:&error] &&
            [owner submitWithError:&error] &&
            [surfaces waitUntilIdleWithError:&error], error);
    cpu_write(dma_a.address, 4);
    const float replacement = 2.25f;
    memcpy(state->vram_ptr + dma_a.address, &replacement, 4);
    require([owner completeWithError:&error], error);
    assert(pg->vertex_attributes[0].inline_value[0] == data[0]);
    [owner getSourcePreview:&preview attributes:1];
    assert(preview.attributes[0].count == 4);
    [owner close];
    printf("Constant Float boundaries: %u changed-source NaN/range/USER-FULL GPU "
           "agreements; stale preview cannot admit faults,pending/submitted writers,format/DMA/bounds/dirty/restore/"
           "cancel reject reuse,retired-reader CPU write cannot relabel old Current PASS\n", cases);
}

static void constant_cmp_components(void)
{
    NSError *error = nil;
    require([surfaces discardForRestoreWithError:&error], error);
    reset();
    PGRAPHState *pg = &state->pgraph;
    pg->draw_arrays_length = 1;
    pg->draw_arrays_count[0] = 1;
    for (unsigned i = 0; i < 16; i++)
        pg->vertex_attributes[i] = (VertexAttribute){
            .offset = i * 4, .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP,
            .size = 4, .count = 1, .stride = 0
        };
    NV2AMetalPGRAPHFetch *owner = [[NV2AMetalPGRAPHFetch alloc]
        initWithState:state surfaces:surfaces error:&error];
    require(owner != nil, error);
    BOOL xSeen[2048] = { 0 }, ySeen[2048] = { 0 }, zSeen[1024] = { 0 };
    for (unsigned base = 0; base < 2048; base += 16) {
        uint32_t packed[16];
        for (unsigned i = 0; i < 16; i++) {
            unsigned x = base + i, y = (x * 123 + 17) & 2047,
                     z = (x * 37 + 11) & 1023;
            packed[i] = x | (y << 11) | (z << 22);
            xSeen[x] = ySeen[y] = zSeen[z] = YES;
        }
        cpu_write(dma_a.address, sizeof(packed));
        memcpy(state->vram_ptr + dma_a.address, packed, sizeof(packed));
        NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
            [owner encodeCurrentSnapshotsWithPrefixes:@[ @0 ] indexedInput:nil error:&error];
        require(batches != nil, error);
        NV2AMetalFetchResult *f = batches[0].fetch;
        NV2AMetalFetchUniforms proof;
        assert([f getReadonlyProofUniforms:&proof attributeBuffer:f.attributes
                    first:0 count:1 commands:surfaces.commands]);
        require([owner completeCurrentSnapshotsWithError:&error] &&
                [surfaces submitWithError:&error] &&
                [surfaces waitUntilIdleWithError:&error], error);
        const NV2AMetalProgramInput *actual = f.attributes.contents;
        for (unsigned i = 0; i < 16; i++)
            assert(!proof.attributes[i].count &&
                   !memcmp(actual->attributes[i], proof.attributes[i].inline_value, 16) &&
                   !memcmp(pg->vertex_attributes[i].inline_value, actual->attributes[i], 16));
    }
    for (unsigned i = 0; i < 2048; i++)
        assert(xSeen[i] && ySeen[i] && (i >= 1024 || zSeen[i]));
    [owner close];
    puts("Constant CMP components: all 2048 X,2048 Y,1024 Z codes covered in "
         "2048 packed values; all 16 attributes,host proof/Current/GPU Float4 "
         "bytes identical including negative endpoint clamps PASS");
}

static void constant_typed_proof_tests(void)
{
    enum {
        D3D = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
        OGL = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
        S1 = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1,
        RAW = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K,
        F = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
        CMP = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP
    };
    const struct {
        unsigned format, count;
        uint32_t bits[4];
        float first;
        BOOL nan;
    } samples[] = {
        { D3D, 4, { 0x80ff000a }, 10.0f / 255, NO },
        { OGL, 1, { 255 }, 1, NO },
        { OGL, 3, { 0x0080ff00 }, 0, NO },
        { S1, 4, { 0x00008000, 0x7fff4000 }, -1, NO },
        { S1, 1, { 0x7fff }, 1, NO },
        { RAW, 4, { 0xffff0001, 0x80007fff }, 1, NO },
        { RAW, 2, { 0x0000ffff }, -1, NO },
        { RAW, 3, { 0x7fff }, 32767, NO },
        { RAW, 1, { 0x8000 }, -32768, NO },
        { CMP, 1, { (1023u << 11) | (511u << 22) }, 0, NO },
        { CMP, 1, { 1024u | (1024u << 11) | (512u << 22) }, -1, NO },
        { CMP, 1, { 511u | (1025u << 11) | (513u << 22) }, 511.0f / 1023, NO },
        { F, 1, { 0x3f800000 }, 1, NO },
        { F, 4, { 0x7fc12345, 0, 0, 0x3f800000 }, 0, YES },
        { F, 3, { 0xbf800000 }, -1, NO },
    };
    NSError *error = nil;
    NV2AMetalCommands *commands = surfaces.commands;
    NV2AMetalWritableProgram *engine = [[NV2AMetalWritableProgram alloc]
        initWithDevice:commands.device error:&error];
    NV2AMetalValidatedProgram *program = constant_read_program(&error);
    require(engine && program, error);
    NV2AMetalProgramUniforms u = { 0 };
    u.surface_size[0] = u.surface_size[1] = 8;
    u.zmax = 65535;
    u.point_scale = u.point_size = 1;
    for (unsigned row = 0; row < 192; row++) {
        u.constants[row][row % 3] = row + .25f;
        u.constants[row][3] = 1;
    }
    unsigned cases = 0, admitted = 0;
    for (unsigned sample = 0; sample < ARRAY_SIZE(samples); sample++)
        for (unsigned hostSeed = 0; hostSeed < 2; hostSeed++)
            for (unsigned indexed = 0; indexed < 2; indexed++)
                for (unsigned access = 0; access < 2; access++) {
                    @autoreleasepool {
                        const unsigned format = samples[sample].format,
                                       count = samples[sample].count;
                        require([surfaces discardForRestoreWithError:&error], error);
                        reset();
                        PGRAPHState *pg = &state->pgraph;
                        pg->vertex_attributes[3] = (VertexAttribute){
                            .format = format, .count = count, .stride = 0,
                            .size = format == S1 || format == RAW ? 2 :
                                    format == D3D || format == OGL ? 1 : 4
                        };
                        if (indexed) {
                            pg->inline_elements_length = 3;
                            const uint32_t indices[] = { UINT32_MAX, 0, 32767 };
                            memcpy(pg->inline_elements, indices, sizeof(indices));
                        } else {
                            pg->draw_arrays_length = 1;
                            pg->draw_arrays_start[0] = 9;
                            pg->draw_arrays_count[0] = 3;
                        }
                        cpu_write(dma_a.address, sizeof(samples[sample].bits));
                        memcpy(state->vram_ptr + dma_a.address, samples[sample].bits,
                               sizeof(samples[sample].bits));
                        NV2AMetalPGRAPHFetch *owner = [[NV2AMetalPGRAPHFetch alloc]
                            initWithState:state surfaces:surfaces error:&error];
                        require(owner != nil, error);
                        NSArray *seed = hostSeed ?
                            [owner encodeCurrentSnapshotsWithPrefixes:@[ @0 ] indexedInput:nil error:&error] :
                            [owner encodeIndependentSnapshotsWithError:&error];
                        require(seed && (hostSeed ? [owner completeCurrentSnapshotsWithError:&error] :
                                                   [owner completeWithError:&error]), error);
                        if (hostSeed)
                            require([surfaces submitWithError:&error] &&
                                    [surfaces waitUntilIdleWithError:&error], error);
                        NV2AMetalFetchUniforms preview;
                        [owner getSourcePreview:&preview attributes:1u << 3];
                        assert(!preview.attributes[3].count && preview.attributes[3].format == format);
                        if (samples[sample].nan)
                            assert(isnan(preview.attributes[3].inline_value[0]));
                        else
                            scalar(preview.attributes[3].inline_value[0], samples[sample].first);
                        /* Equal-width, equal-count F/CMP rebinds still change the source domain. */
                        pg->vertex_attributes[3].format = format == F ? CMP : F;
                        [owner getSourcePreview:&preview attributes:1u << 3];
                        assert(preview.attributes[3].count == count);
                        pg->vertex_attributes[3].format = format;
                        NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
                            [owner encodeCurrentSnapshotsWithPrefixes:@[ @0 ] indexedInput:nil error:&error];
                        require(batches != nil, error);
                        NV2AMetalFetchResult *f = batches[0].fetch;
                        NV2AMetalFetchUniforms proof, raw;
                        assert([f getSourceUniforms:&raw attributeBuffer:f.attributes first:0 count:3 commands:commands] &&
                               [f getReadonlyProofUniforms:&proof attributeBuffer:f.attributes first:0 count:3 commands:commands] &&
                               raw.attributes[3].format == format && raw.attributes[3].count == count &&
                               !proof.attributes[3].count);
                        NV2AMetalWritableEncoding *candidate = [engine encodeProgram:program
                            uniforms:&u attributeBuffer:f.attributes first:0 count:3 access:access
                            writeEnable:NO rasterize:YES compactRegisters:YES attributeFetch:f
                            commands:commands error:&error];
                        NV2AMetalWritableEncoding *reference = [engine encodeProgram:program
                            uniforms:&u attributeBuffer:f.attributes first:0 count:3 access:access
                            writeEnable:NO rasterize:YES compactRegisters:NO
                            commands:commands error:&error];
                        require(candidate && reference, error);
                        BOOL valid = !samples[sample].nan && samples[sample].first <= 95 &&
                                     samples[sample].first >= (access ? -96 : 0);
                        assert([candidate canUsePendingReadOnlyResultForCommands:commands] == valid);
                        require([owner completeCurrentSnapshotsWithError:&error] &&
                                [surfaces submitWithError:&error] &&
                                [surfaces waitUntilIdleWithError:&error], error);
                        const NV2AMetalProgramInput *decoded = f.attributes.contents;
                        for (unsigned v = 0; v < 3; v++)
                            assert(!memcmp(decoded[v].attributes[3], proof.attributes[3].inline_value, 16));
                        assert(!memcmp(pg->vertex_attributes[3].inline_value, proof.attributes[3].inline_value, 16));
                        error = nil;
                        NV2AMetalWritableResult *actual = [candidate resolveWithError:&error];
                        assert((actual != nil) == valid && (error != nil) == !valid);
                        error = nil;
                        NV2AMetalWritableResult *golden = [reference resolveWithError:&error];
                        assert((golden != nil) == valid && (error != nil) == !valid);
                        if (valid)
                            assert(actual.vertices.length == golden.vertices.length &&
                                   !memcmp(actual.vertices.contents, golden.vertices.contents, actual.vertices.length));
                        [owner close];
                        error = nil;
                        cases++;
                        admitted += valid;
                    }
                }
    printf("Constant typed proof: %u cases,%u admissions; all six formats,"
           "host/GPU seeds,array/indexed,USER/FULL,CMP clamp,D3D lane order,"
           "S32K limits,NaN,default lanes,equal-width format rebinds; exact "
           "decoded GPU bytes and generic XF faults/vertices PASS\n", cases, admitted);
    constant_cmp_components();
}

static void index_ranges_tests(void)
{
    NSError *error = nil;
    require([surfaces discardForRestoreWithError:&error], error);
    reset();
    NV2AMetalPGRAPHFetch *owner =
        [[NV2AMetalPGRAPHFetch alloc] initWithState:state
                                           surfaces:surfaces
                                              error:&error];
    require(owner != nil, error);
    PGRAPHState *pg = &state->pgraph;
    pg->vertex_attributes[0] =
        (VertexAttribute){ .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                           .size = 4,
                           .count = 4,
                           .stride = 16 };
    cpu_write(dma_a.address, 64 * 16);
    for (unsigned i = 0; i < 64; i++)
        for (unsigned lane = 0; lane < 4; lane++) {
            float value = i * 10 + lane + .25f;
            memcpy(state->vram_ptr + dma_a.address + i * 16 + lane * 4, &value,
                   4);
        }
    pg->inline_elements_length = 128;
    const uint32_t selection[] = { 0, 1, 4, 7, 8, 15 };
    for (unsigned i = 0; i < 124; i++)
        pg->inline_elements[i] = selection[(i * 5) % 6];
    const uint32_t tail[] = { 15, 7, 4, 0 };
    memcpy(pg->inline_elements + 124, tail, sizeof(tail));
    NV2AMetalPendingInput *input =
        [NV2AMetalPendingInput indexedBytes:pg->inline_elements
                                      count:128
                           matchingPrevious:nil];
    NSData *cached = index_ranges_run(owner, input, 0, NO);
    assert(cached && cached == index_ranges_run(owner, input, 0, NO));
    /* Force an existing slice ahead of the indexed suffix in the arena.
     * Reading from the start of its backing buffer would select vertex 0. */
    const uint32_t zeros[128] = { 0 };
    NSUInteger offset = NSUIntegerMax;
    require([surfaces prepareGPUReadAtAddress:0 length:0 error:&error] &&
                [surfaces.commands uploadBytes:zeros
                                        length:sizeof(zeros)
                                        offset:&offset
                                         error:&error],
            error);
    assert(offset == 0);
    assert(cached == index_ranges_run(owner, input, 0, YES));
    NSData *suffix = index_ranges_run(owner, input, 124, NO);
    assert(suffix != cached && suffix.length == 4 * sizeof(NSRange) &&
           suffix == index_ranges_run(owner, input, 124, NO));

    /* A warm cache must neither guard nor download a hole in its suffix. */
    NV2AMetalCachedSurface *dirty = index_ranges_writer(8);
    unsigned before = notifications;
    id recording = surfaces.commands.commandBuffer;
    NV2AMetalSurfaceRecording *token = surfaces.recording;
    assert(index_ranges_run(owner, input, 124, NO) == suffix && dirty.dirty &&
           notifications == before && !token.submitted && !token.cancelled &&
           surfaces.commands.commandBuffer == recording &&
           surfaces.recording == token);

    /* Equal length and prefix with different indices must protect that hole. */
    pg->inline_elements[125] = 8;
    NV2AMetalPendingInput *changed =
        [NV2AMetalPendingInput indexedBytes:pg->inline_elements
                                      count:128
                           matchingPrevious:input];
    NSData *changedRanges = index_ranges_run(owner, changed, 124, NO);
    assert(changed != input && changedRanges != suffix && !dirty.dirty &&
           notifications == before + 1);
    dirty = index_ranges_writer(4);
    before = notifications;
    assert(changedRanges == index_ranges_run(owner, changed, 124, NO) &&
           !dirty.dirty && notifications == before + 1);

    NSData *last = index_ranges_run(owner, changed, 127, NO);
    dma_a.limit = 15; /* Current fits; the full input maximum does not. */
    VertexAttribute saved[16];
    memcpy(saved, pg->vertex_attributes, sizeof(saved));
    pg->compressed_attrs = 0x40;
    error = nil;
    assert(![owner encodeIndependentSnapshotsWithPrefixes:@[ @127 ]
                                             indexedInput:changed
                                                    error:&error] &&
           error && !memcmp(saved, pg->vertex_attributes, sizeof(saved)) &&
           pg->compressed_attrs == 0x40 &&
           [owner valueForKey:@"indexRanges"] == last);
    dma_a.limit = 65535;
    assert(index_ranges_run(owner, changed, 127, NO) == last);
    index_ranges_run(owner, changed, 128, NO);
    assert(index_ranges_run(owner, changed, 128, YES).length == sizeof(NSRange));

    /* Cancellation preserves pure metadata, not an old read registration. */
    error = nil;
    require([owner encodeIndependentSnapshotsWithPrefixes:@[ @124 ]
                                             indexedInput:changed
                                                    error:&error] != nil,
            error);
    NSData *retry = [owner valueForKey:@"indexRanges"];
    [owner cancel];
    assert(retry == index_ranges_run(owner, changed, 124, NO));
    NV2AMetalPendingInput *equal =
        [NV2AMetalPendingInput indexedBytes:changed.indices.bytes
                                      count:128
                           matchingPrevious:nil];
    assert(equal != changed &&
           index_ranges_run(owner, equal, 124, NO) == retry);
    /* Cross-object reuse is only a range-plan hit. A newly dirty source must
     * still download before this descriptor's GPU fetch consumes its bytes. */
    dirty = index_ranges_writer(8);
    before = notifications;
    NV2AMetalPendingInput *again = [NV2AMetalPendingInput
        indexedBytes:equal.indices.bytes count:128 matchingPrevious:nil];
    assert(index_ranges_run(owner, again, 124, NO) == retry && !dirty.dirty &&
           notifications == before + 1);
    assert(!index_ranges_run(owner, nil, 124, NO));
    pg->inline_elements[125] = 1;
    assert(!index_ranges_run(owner, nil, 124, NO));

    __weak NV2AMetalPendingInput *weakInput;
    @autoreleasepool {
        NV2AMetalPendingInput *temporary =
            [NV2AMetalPendingInput indexedBytes:pg->inline_elements
                                          count:128
                               matchingPrevious:nil];
        weakInput = temporary;
        index_ranges_run(owner, temporary, 124, NO);
    }
    assert(!weakInput && ![owner valueForKey:@"indexRangesInput"]);
    NSData *orphan = [owner valueForKey:@"indexRanges"];
    NV2AMetalPendingInput *replacement = [NV2AMetalPendingInput
        indexedBytes:pg->inline_elements count:128 matchingPrevious:nil];
    assert(index_ranges_run(owner, replacement, 124, NO) == orphan);

    /* Constant DMA lanes need one protected element, regardless of indices,
     * prefix or Current publication mode. Disabled strides do not count. */
    pg->vertex_attributes[0].stride = 0;
    pg->vertex_attributes[0].offset = 64;
    pg->vertex_attributes[15].stride = 64;
    for (unsigned hooked = 0; hooked < 2; hooked++)
        for (unsigned host = 0; host < 2; host++)
            for (unsigned accepted = 0; accepted < 2; accepted++)
                for (unsigned immutable = 0; immutable < 2; immutable++) {
                    tcg_allowed = hooked;
                    assert(!index_ranges_run(owner, immutable ? input : nil,
                                            accepted ? 128 : 0, host) &&
                           [owner valueForKey:@"indexRanges"] == orphan);
                }
    tcg_allowed = true;
    dirty = index_ranges_writer(4);
    before = notifications;
    assert(!index_ranges_run(owner, input, 0, NO) && !dirty.dirty &&
           notifications == before + 1);
    dma_a.limit = 78; /* Offset64 plus a Float4 needs an inclusive limit79. */
    memcpy(saved, pg->vertex_attributes, sizeof(saved));
    pg->compressed_attrs = 0x40;
    error = nil;
    assert(![owner encodeIndependentSnapshotsWithPrefixes:@[ @0 ]
        indexedInput:input error:&error] && error &&
        !memcmp(saved, pg->vertex_attributes, sizeof(saved)) &&
        pg->compressed_attrs == 0x40);
    dma_a.limit = 65535;
    pg->vertex_attributes[0].count = 0;
    const float inlineValue[4] = { 19, .5f, -2, 1 };
    memcpy(pg->vertex_attributes[0].inline_value, inlineValue, sizeof(inlineValue));
    dma_a.dma_class = NV_DMA_IN_MEMORY_CLASS + 1;
    unsigned loads = dma_loads;
    error = nil;
    NSArray<NV2AMetalPGRAPHFetchBatch *> *inlineOnly =
        [owner encodeIndependentSnapshotsWithPrefixes:@[ @0 ]
            indexedInput:input error:&error];
    require(inlineOnly != nil, error);
    require([owner completeWithError:&error], error);
    assert(dma_loads == loads && [owner valueForKey:@"indexRanges"] == orphan &&
           !memcmp(values(inlineOnly[0])[0].attributes[0], inlineValue,
                   sizeof(inlineValue)));
    dma_a.dma_class = NV_DMA_IN_MEMORY_CLASS;
    pg->vertex_attributes[0].count = 4;
    pg->vertex_attributes[0].stride = 16;
    pg->vertex_attributes[0].offset = 0;
    assert(index_ranges_run(owner, replacement, 124, NO) == orphan);
    puts("Index-independent lanes:16 host/GPU,TCG/fallback,full/suffix,"
         "immutable/mutable cases skip range plans but protect their source; "
         "dirty download,invalid DMA bounds,inline-only no-DMA and cached "
         "plan survives stride changes PASS");

    /* Exercise both sides of the local read-record capacity. The zero-stride
     * lane is registered once; the nonzero-stride lane has one record per
     * disjoint index. */
    pg->vertex_attributes[7] = pg->vertex_attributes[0];
    pg->vertex_attributes[7].stride = 0;
    for (unsigned count = 31; count <= 32; count++) {
        pg->inline_elements_length = count;
        for (unsigned i = 0; i < count; i++)
            pg->inline_elements[i] = (count - i - 1) * 2;
        NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
            [owner encodeIndependentSnapshotsWithPrefixes:@[ @0 ]
                                              indexedInput:nil error:&error];
        require(batches != nil, error);
        NSData *spans = [[owner valueForKey:@"independentReads"]
            valueForKey:@"spans"];
        const NV2AMetalVRAMReadPattern *records = spans.bytes;
        assert(spans.length == (count + 1) * sizeof(*records));
        assert(records[0].address == dma_a.address && records[0].length == 16);
        for (unsigned i = 0; i < count; i++)
            assert(records[i + 1].address == dma_a.address + i * 32 &&
                   records[i + 1].length == 16 && !records[i + 1].stride);
        require([owner completeWithError:&error], error);
        const NV2AMetalProgramInput *decoded = values(batches[0]);
        for (unsigned i = 0; i < count; i++)
            assert(!memcmp(decoded[i].attributes[0], state->vram_ptr +
                               dma_a.address + pg->inline_elements[i] * 16, 16) &&
                   !memcmp(decoded[i].attributes[7], state->vram_ptr +
                               dma_a.address, 16));
    }
    pg->vertex_attributes[7].count = 0;
    puts("DMA read record storage: 32 and 33 exact records, disjoint "
         "indices and zero stride PASS");

    /* Byte strides keep both sides of the metadata budget inside this VRAM. */
    pg->vertex_attributes[0].stride = 1;
    for (NSUInteger count = 4096; count <= 4097; count++) {
        @autoreleasepool {
            pg->inline_elements_length = count;
            for (NSUInteger i = 0; i < count; i++)
                pg->inline_elements[i] = (uint32_t)((count - i - 1) * 2);
            NV2AMetalPendingInput *large =
                [NV2AMetalPendingInput indexedBytes:pg->inline_elements
                                              count:count
                                   matchingPrevious:nil];
            NSData *range = index_ranges_run(owner, large, 0, NO);
            if (count == 4096)
                assert(range.length == 65536 &&
                       ![owner valueForKey:@"indexRangesKey"] &&
                       range == index_ranges_run(owner, large, 0, NO));
            else
                assert(!range && !index_ranges_run(owner, large, 0, NO) &&
                       ![owner valueForKey:@"indexRangesInput"]);
        }
    }
    /* Dense indices leave room for a byte key. The combined budget includes
     * both its selected input bytes and the immutable range plan. */
    for (NSUInteger count = 16380; count <= 16381; count++) {
        @autoreleasepool {
            pg->inline_elements_length = count;
            for (NSUInteger i = 0; i < count; i++)
                pg->inline_elements[i] = (uint32_t)((i * 25173 + 1) % 32);
            NV2AMetalPendingInput *dense = [NV2AMetalPendingInput
                indexedBytes:pg->inline_elements count:count matchingPrevious:nil];
            NSData *range = index_ranges_run(owner, dense, 0, NO);
            NSData *key = [owner valueForKey:@"indexRangesKey"];
            assert(range.length == sizeof(NSRange) &&
                   (count == 16380 ? key.length + range.length == 65536 : !key));
            NV2AMetalPendingInput *copy = [NV2AMetalPendingInput
                indexedBytes:pg->inline_elements count:count matchingPrevious:nil];
            NSData *next = index_ranges_run(owner, copy, 0, NO);
            assert(count == 16380 ? next == range : next != range);
        }
    }
    pg->inline_elements_length = 128;
    tcg_allowed = false;
    NSData *unhooked = index_ranges_run(owner, input, 128, NO);
    assert(!unhooked.length && [owner valueForKey:@"indexRangesKey"] &&
           [[owner valueForKey:@"indexRangesFirstRead"] unsignedIntegerValue] == 128);
    NV2AMetalPendingInput *unhookedCopy = [NV2AMetalPendingInput
        indexedBytes:input.indices.bytes count:128 matchingPrevious:nil];
    assert(index_ranges_run(owner, unhookedCopy, 128, NO) == unhooked);
    tcg_allowed = true;
    NSData *hooked = index_ranges_run(owner, unhookedCopy, 128, NO);
    assert(hooked.length == sizeof(NSRange) &&
           [[owner valueForKey:@"indexRangesFirstRead"] unsignedIntegerValue] == 127);
    index_ranges_run(owner, input, 124, NO);
    [owner close];
    assert(![owner valueForKey:@"indexRanges"] &&
           ![owner valueForKey:@"indexRangesKey"] &&
           ![owner valueForKey:@"indexRangesInput"]);
    require([surfaces discardForRestoreWithError:&error], error);
    puts("Index range metadata:exact GPU suffix/Current,immutable identity/byte "
         "and prefix hits/misses,dirty hole and fresh writer protection,full DMA "
         "rejection/retry,cancel,mutable bypass,weak input,combined 64KiB bound and "
         "nonzero index upload offset "
         "PASS");
}

static unsigned fetch_alias_validations, fetch_alias_disjoint_probes;
static NV2AMetalCachedSurface *fetch_alias_disjoint_surface;
static BOOL (*fetch_alias_original_dirty)(id, SEL);
static BOOL (*fetch_alias_original_validate)(
    id, SEL, const NV2AMetalVRAMReadPattern *, NSUInteger, NSRange *,
    NSUInteger *, NSError **);

static BOOL fetch_alias_validate(id object, SEL selector,
                                 const NV2AMetalVRAMReadPattern *patterns,
                                 NSUInteger count, NSRange *bounds,
                                 NSUInteger *nonempty,
                                 NSError **error)
{
    if (object == surfaces)
        fetch_alias_validations++;
    return fetch_alias_original_validate(object, selector, patterns, count,
                                         bounds, nonempty, error);
}

static BOOL fetch_alias_dirty(id object, SEL selector)
{
    if (object == fetch_alias_disjoint_surface)
        fetch_alias_disjoint_probes++;
    return fetch_alias_original_dirty(object, selector);
}

static void fetch_alias_prefix_tests(void)
{
    NSError *error = nil;
    id<MTLDevice> device = surfaces.commands.device;
    NV2AMetalClear *clear = [[NV2AMetalClear alloc] initWithDevice:device
                                                           error:&error];
    require(clear != nil, error);
    const NSUInteger addresses[] = { 12288, 16896 };
    const NV2AMetalSurfaceConfig config = {
        .format = NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        .width = 4, .height = 4, .pitch = 16, .scale = 1, .color = YES,
    };
    const uint32_t oldColor = 0xff123456;
    for (unsigned fallback = 0; fallback < 2; fallback++) {
        require([surfaces discardForRestoreWithError:&error], error);
        reset();
        dma_a.address = 0;
        PGRAPHState *pg = &state->pgraph;
        pg->draw_arrays_length = pg->draw_arrays_count[0] = 1;
        NV2AMetalCachedSurface *disjoint =
            [surfaces prepareSurfaceAtAddress:60000 config:&config frame:1
                                        error:&error];
        require(disjoint != nil, error);
        NV2AMetalCachedSurface *targets[2];
        for (unsigned i = 0; i < 2; i++) {
            cpu_write(addresses[i], 64);
            memcpy(state->vram_ptr + addresses[i], &oldColor, sizeof(oldColor));
            targets[i] = [surfaces prepareSurfaceAtAddress:addresses[i]
                                                    config:&config frame:1
                                                     error:&error];
            require(targets[i] != nil, error);
            pg->vertex_attributes[i] = (VertexAttribute){
                .offset = addresses[i], .count = 4, .size = 1, .stride = 4,
                .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
            };
        }
        require([surfaces submitWithError:&error] &&
                    [surfaces waitUntilIdleWithError:&error], error);
        NV2AMetalCommands *readerCommands =
            [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
        require(readerCommands != nil, error);
        const NV2AMetalVRAMReadSpan span = { addresses[1], sizeof(oldColor) };
        NV2AMetalIndependentReads *reader = nil;
        require([surfaces tryBeginIndependentReads:&span count:1
                                          commands:readerCommands reads:&reader
                                             error:&error] && reader, error);
        id<MTLBuffer> before =
            [device newBufferWithLength:span.length
                                options:MTLResourceStorageModeShared];
        require(before && [readerCommands addResource:before error:&error],
                error);
        id<MTL4ComputeCommandEncoder> copy =
            [readerCommands.commandBuffer computeCommandEncoder];
        assert(copy);
        [copy copyFromBuffer:surfaces.vram sourceOffset:span.address
                   toBuffer:before destinationOffset:0 size:span.length];
        [copy endEncoding];
        id<MTLSharedEvent> gate = [device newSharedEvent];
        Ivar ivar = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
        id<MTL4CommandQueue> queue = object_getIvar(readerCommands, ivar);
        assert(gate && queue);
        [queue waitForEvent:gate value:1];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                         if (!gate.signaledValue)
                             gate.signaledValue = 2;
                       });
        require([surfaces submitIndependentReads:reader error:&error], error);
        for (unsigned i = 0; i < 2; i++) {
            NV2AMetalClearConfig color = {
                .parameter = NV097_CLEAR_SURFACE_COLOR,
                .rect = { 0, 0, 4, 4 },
                .uniforms = { .color = { !i, i, 0, 1 } },
            };
            require([surfaces prepareSelectedSurface:targets[i]
                                  discardingContents:YES error:&error] &&
                        [clear encodeColor:targets[i].transfer.texture zeta:nil
                                    config:&color commands:surfaces.commands
                                     error:&error] &&
                        [surfaces markWritten:targets[i] replacingContents:YES
                                        error:&error], error);
        }
        NV2AMetalSurfaceRecording *prefix = surfaces.recording;
        require([surfaces checkpointWithError:&error], error);
        Method validate = class_getInstanceMethod(
            NV2AMetalSurfaceCache.class,
            sel_registerName("validateReadPatterns:count:bounds:nonempty:error:"));
        Method dirty = class_getInstanceMethod(NV2AMetalCachedSurface.class,
                                               @selector(dirty));
        assert(validate && dirty);
        fetch_alias_validations = 0;
        fetch_alias_disjoint_surface = disjoint;
        fetch_alias_disjoint_probes = 0;
        fetch_alias_original_validate =
            (void *)method_setImplementation(validate, (IMP)fetch_alias_validate);
        fetch_alias_original_dirty =
            (void *)method_setImplementation(dirty, (IMP)fetch_alias_dirty);
        NSArray<NV2AMetalPGRAPHFetchBatch *> *batches =
            fallback ? [adapter encodeIndependentSnapshotsWithError:&error] :
                       [adapter encodeWithError:&error];
        method_setImplementation(validate, (IMP)fetch_alias_original_validate);
        method_setImplementation(dirty, (IMP)fetch_alias_original_dirty);
        fetch_alias_disjoint_surface = nil;
        require(batches.count == 1, error);
        assert(fetch_alias_validations == 1 && fetch_alias_disjoint_probes == 1);
        NV2AMetalSurfaceRecording *fetch = surfaces.recording;
        assert(prefix.submitted && fetch && !fetch.submitted &&
               adapter.encodingCommands == surfaces.commands &&
               !gate.signaledValue);
        require([surfaces waitForSubmission:surfaces.commands.lastSubmitted
                                      error:&error], error);
        assert(prefix.completed && surfaces.recording == fetch &&
               !gate.signaledValue);
        require([adapter submitWithError:&error], error);
        gate.signaledValue = 1;
        require([adapter completeWithError:&error] &&
                    [surfaces completeIndependentReads:reader error:&error],
                error);
        assert(!memcmp(before.contents, &oldColor, sizeof(oldColor)));
        const NV2AMetalProgramInput *decoded = values(batches[0]);
        scalar(decoded->attributes[0][0], 1);
        scalar(decoded->attributes[0][1], 0);
        scalar(decoded->attributes[1][0], 0);
        scalar(decoded->attributes[1][1], 1);
        scalar(pg->vertex_attributes[0].inline_value[2], 1);
        scalar(pg->vertex_attributes[1].inline_value[1], 1);
    }
    require([surfaces discardForRestoreWithError:&error], error);
    puts("Fetch alias prefix: shared and fallback queues submit prior clears "
         "ahead of the gated second attribute; both decoded values and "
         "Current match; one DMA batch validation on either path, "
         "one dirty surface scan PASS");
    groups++;
}
#include "test-metal-array-range-plan.h"
#include "test-metal-readonly-index-plan.h"
#include "test-metal-readonly-index-plan-reuse.h"
#include "test-metal-float-proof-capture.h"
#include "test-metal-indexed-float-capture.h"
#include "test-metal-float-summary-memo.h"
#include "test-metal-array-float-windows.h"

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
                         ((address == 1088 || address == 1152 ||
                           address == 65520) &&
                          length == 16));
                  notifications++;
                }
                       error:&error];
        require(surfaces != nil, error);
        adapter = [[NV2AMetalPGRAPHFetch alloc] initWithState:state
                                                     surfaces:surfaces
                                                        error:&error];
        require(adapter != nil, error);
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--array-float-windows")))
            array_float_windows_tests();
        if (argc == 2 && !strcmp(argv[1], "--array-float-windows"))
            goto close;
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--readonly-index-plan-reuse")))
            readonly_index_plan_reuse_tests();
        if (argc == 2 && !strcmp(argv[1], "--readonly-index-plan-reuse"))
            goto close;
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--float-summary-memo")))
            float_summary_memo_tests();
        if (argc == 2 && !strcmp(argv[1], "--float-summary-memo"))
            goto close;
        if (argc == 1 ||
            (argc == 2 && !strcmp(argv[1], "--indexed-float-capture")))
            indexed_float_capture_tests();
        if (argc == 2 && !strcmp(argv[1], "--indexed-float-capture"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--float-proof-capture")))
            float_proof_capture_tests();
        if (argc == 2 && !strcmp(argv[1], "--float-proof-capture"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--readonly-index-plan")))
            readonly_index_plan_tests();
        if (argc == 2 && !strcmp(argv[1], "--readonly-index-plan"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--array-range-plan")))
            array_range_plan_tests();
        if (argc == 2 && !strcmp(argv[1], "--array-range-plan"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--readonly-dedupe")))
            fetch_readonly_dedupe_tests();
        if (argc == 2 && !strcmp(argv[1], "--readonly-dedupe"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--constant-typed-proof")))
            constant_typed_proof_tests();
        if (argc == 2 && !strcmp(argv[1], "--constant-typed-proof"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--constant-float-proof")))
            constant_float_proof_tests();
        if (argc == 2 && !strcmp(argv[1], "--constant-float-proof"))
            goto close;
        if (argc == 2 && !strcmp(argv[1], "--index-ranges-wide-benchmark")) {
            index_ranges_wide_benchmark();
            goto close;
        }
        if (argc == 2 &&
            (!strcmp(argv[1], "--index-ranges-benchmark") ||
             !strcmp(argv[1], "--index-ranges-zero-stride-benchmark") ||
             !strcmp(argv[1], "--index-ranges-changing-benchmark"))) {
            index_ranges_benchmark(!strcmp(argv[1], "--index-ranges-zero-stride-benchmark"),
                                   !strcmp(argv[1], "--index-ranges-changing-benchmark"));
            goto close;
        }
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--index-range-words")))
            index_range_word_tests();
        if (argc == 2 && !strcmp(argv[1], "--index-range-words"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--index-range-radix")))
            index_range_radix_tests();
        if (argc == 2 && !strcmp(argv[1], "--index-range-radix"))
            goto close;
        if (argc == 1 || (argc == 2 && !strcmp(argv[1], "--index-ranges")))
            index_ranges_tests();
        if (argc == 2 && !strcmp(argv[1], "--index-ranges"))
            goto close;
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
        fetch_alias_prefix_tests();
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
