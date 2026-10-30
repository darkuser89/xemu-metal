/* Immutable report prefixes within a live native Begin.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_REPORT_BOUNDARIES_H
#define TEST_METAL_REPORT_BOUNDARIES_H
#include "hw/xbox/nv2a/pgraph/metal/renderer.h"

static void rb_fixture(void)
{
    fixture();
    [draw.reports discard];
    memset(report_seen, 0, sizeof(report_seen));
    memset(report_values, 0xa5, sizeof(report_values));
    state->pgraph.dma_report = 64;
    const float positions[6][4] = {
        { 0, 0, 32768, 1 }, { 8, 0, 32768, 1 }, { 0, 8, 32768, 1 },
        { 4, 4, 32768, 1 }, { 8, 4, 32768, 1 }, { 4, 8, 32768, 1 },
    };
    cpu_write(16384, sizeof(positions));
    memcpy(state->vram_ptr + 16384, positions, sizeof(positions));
}
static void rb_batch(unsigned first, unsigned count)
{
    PGRAPHState *pg = &state->pgraph;
    pg->draw_arrays_length = count != 0;
    pg->draw_arrays_start[0] = first;
    pg->draw_arrays_count[0] = count;
}
static void rb_get(unsigned slot)
{
    NSError *error = nil;
    require([draw.reports getReport:1u << 24 | slot * 16 error:&error], error);
}
static void rb_process(void)
{
    NSError *error = nil;
    require([draw.reports processWithError:&error], error);
}
static void rb_expect(unsigned slot, uint32_t value)
{
    if (!report_seen[slot] || report_values[slot] != value) {
        fprintf(stderr, "Report boundary slot%u:seen%u got%u expected%u\n",
                slot, report_seen[slot], report_values[slot], value);
        abort();
    }
}
static unsigned rb_cases = 1, rb_rejects;
static void rb_clear_tests(void)
{
    for (unsigned queued = 0; queued < 2; queued++) {
        rb_fixture();
        NSError *error = nil;
        qemu_mutex_lock(&state->pgraph.lock);
        state->pgraph.zpass_pixel_count_enable = true;
        require([draw beginWithError:&error], error);
        require([draw flushDrawWithError:&error], error);
        rb_batch(0, 0);
        if (queued)
            rb_get(0);
        [draw.reports clear];
        rb_get(1);
        rb_batch(3, 3);
        require([draw flushDrawWithError:&error], error);
        rb_batch(0, 0);
        rb_get(2);
        rb_process();
        if (queued)
            rb_expect(0, 28);
        rb_expect(1, 0);
        rb_expect(2, 6);
        require([draw endWithError:&error], error);
        rb_get(3);
        rb_process();
        rb_expect(3, 6);
        qemu_mutex_unlock(&state->pgraph.lock);
        rb_cases++;
    }
}
static void rb_pending_and_enable_tests(void)
{
    for (unsigned enabled = 0; enabled < 2; enabled++) {
        rb_fixture();
        NSError *error = nil;
        qemu_mutex_lock(&state->pgraph.lock);
        PGRAPHState *pg = &state->pgraph;
        pg->zpass_pixel_count_enable = enabled;
        require([draw beginWithError:&error], error);
        float current[4];
        memcpy(current, pg->vertex_attributes[0].inline_value, sizeof(current));
        rb_get(0); // Report does not execute unflushed common input.
        rb_process();
        rb_expect(0, 0);
        assert(pg->draw_arrays_length == 1 && pg->draw_arrays_count[0] == 3 &&
               !memcmp(current, pg->vertex_attributes[0].inline_value,
                       sizeof(current)) &&
               pg->draw_time == 0);
        pg->zpass_pixel_count_enable = !enabled;
        [draw.reports clear];
        require([draw endWithError:&error], error);
        rb_get(1);
        rb_process();
        rb_expect(1, enabled ? 28 : 0);
        rb_batch(0, 3);
        require([draw beginWithError:&error], error);
        require([draw endWithError:&error], error);
        rb_get(2);
        rb_process();
        rb_expect(2, 28); // Each subsequent Begin captures the new enable bit.
        qemu_mutex_unlock(&pg->lock);
        rb_cases++;
    }
}
static void rb_failure_test(void)
{
    rb_fixture();
    NSError *error = nil;
    qemu_mutex_lock(&state->pgraph.lock);
    state->pgraph.zpass_pixel_count_enable = true;
    require([draw beginWithError:&error], error);
    require([draw flushDrawWithError:&error], error);
    rb_get(0);
    rb_batch(3, 3);
    dma[2].limit = 46;
    assert(![draw endWithError:&error] && error &&
           state->pgraph.draw_time == 0);
    rb_process();
    rb_expect(0, 28);
    dma[2].limit = 1023;
    require([draw endWithError:&error], error);
    rb_get(1);
    rb_process();
    rb_expect(1, 34);
    assert(state->pgraph.draw_time == 1);
    qemu_mutex_unlock(&state->pgraph.lock);
    rb_cases++;
}
static void rb_counter(NV2AMetalPGRAPHQuery *query, uint64_t count)
{
    id<MTLBuffer> b = [surfaces.cache.commands.device
        newBufferWithBytes:&count
                    length:sizeof(count)
                   options:MTLResourceStorageModeShared];
    assert(b);
    [draw.reports commitBuffer:b query:query];
}
static void rb_rounding_tests(void)
{
    for (unsigned scale = 1; scale <= 3; scale++) {
        rb_fixture();
        qemu_mutex_lock(&state->pgraph.lock);
        state->pgraph.surface_scale_factor = scale;
        unsigned divisor = scale * scale;
        NV2AMetalPGRAPHQuery *q = [draw.reports beginQuery];
        rb_counter(q, divisor - 1);
        rb_get(0);
        rb_counter(q, 1);
        rb_get(1);
        rb_counter(q, divisor - 1);
        [draw.reports endQuery:q];
        rb_get(2);
        rb_process();
        rb_expect(0, 0);
        rb_expect(1, 1);
        rb_expect(2, (2 * divisor - 1) / divisor);
        // Different Begins still truncate independently, as before M33.
        for (unsigned i = 0; i < 2; i++) {
            q = [draw.reports beginQuery];
            rb_counter(q, divisor - 1);
            [draw.reports endQuery:q];
        }
        rb_get(3);
        rb_process();
        rb_expect(3, (2 * divisor - 1) / divisor);
        [draw.reports clear];
        q = [draw.reports beginQuery];
        rb_counter(q, UINT32_MAX);
        rb_get(4);
        rb_counter(q, 8);
        rb_get(5);
        rb_process();
        rb_expect(4, UINT32_MAX / divisor);
        rb_expect(5, 7 / divisor); // Wrap the whole Begin before division.
        [draw.reports clear];
        rb_counter(q, divisor - 1);
        rb_get(6);
        rb_process();
        rb_expect(6, 0); // Clear also discards the fractional prefix.
        rb_counter(q, 1);
        [draw.reports endQuery:q];
        rb_get(7);
        rb_process();
        rb_expect(7, 1);
        qemu_mutex_unlock(&state->pgraph.lock);
        rb_cases++;
    }
    rb_fixture();
    qemu_mutex_lock(&state->pgraph.lock);
    NV2AMetalPGRAPHQuery *q = [draw.reports beginQuery];
    rb_counter(q, UINT64_MAX);
    rb_get(0);
    rb_counter(q, 2);
    rb_get(1);
    [draw.reports cancelQuery:q];
    rb_process();
    rb_expect(0, UINT32_MAX);
    rb_expect(1, 1); // Frozen reports survive cancellation of the live query.
    rb_get(2);
    rb_process();
    rb_expect(2, 1);
    qemu_mutex_unlock(&state->pgraph.lock);
    rb_cases++;
}
static void rb_snapshot_tests(void)
{
    for (unsigned processed = 0; processed < 2; processed++) {
        rb_fixture();
        NSError *error = nil;
        qemu_mutex_lock(&state->pgraph.lock);
        state->pgraph.zpass_pixel_count_enable = true;
        require([draw beginWithError:&error], error);
        require([draw flushDrawWithError:&error], error);
        rb_batch(0, 0);
        rb_get(0);
        if (processed)
            rb_process();
        NSData *report = [draw reportSnapshotWithError:&error];
        NSData *vertex = [draw vertexSnapshot];
        NSData *begin = [draw beginSnapshotWithError:&error];
        require(report && vertex && begin, error);
        assert(ldl_be_p((const uint8_t *)report.bytes + 4) == 3);
        require([draw flushWithError:&error], error);
        require([draw discardForRestoreWithError:&error], error);
        require([draw restoreVertexSnapshot:vertex error:&error], error);
        require([draw restoreBeginSnapshot:begin error:&error], error);
        require([draw restoreReportSnapshot:report error:&error], error);
        assert([[draw reportSnapshotWithError:&error] isEqualToData:report]);
        require([draw beginWithError:&error], error);
        rb_batch(3, 3);
        require([draw flushDrawWithError:&error], error);
        rb_batch(0, 0);
        require([draw endWithError:&error], error);
        rb_get(1);
        rb_process();
        rb_expect(0, 28);
        rb_expect(1, 34);
        qemu_mutex_unlock(&state->pgraph.lock);
        rb_cases++;
    }
}
static void rb_append32(NSMutableData *data, uint32_t value)
{
    uint32_t be = cpu_to_be32(value);
    [data appendBytes:&be length:4];
}
static void rb_append64(NSMutableData *data, uint64_t value)
{
    uint64_t be = cpu_to_be64(value);
    [data appendBytes:&be length:8];
}
static NSData *rb_wire(unsigned version)
{
    NSMutableData *data = [NSMutableData new];
    const uint32_t h[] = { 0x4d345250, version, 0, 1, 0, UINT32_MAX, 2 };
    for (unsigned i = 0; i < (version == 1 ? 6u : 7u); i++)
        rb_append32(data, h[i]);
    rb_append64(data, 37);
    if (version == 3)
        rb_append64(data, 11);
    rb_append32(data, 0); // Closed query in the pending list.
    rb_append32(data, 1);
    rb_append32(data, 0);
    return data;
}
static void rb_wire_tests(void)
{
    rb_fixture();
    NSError *error = nil;
    qemu_mutex_lock(&state->pgraph.lock);
    for (unsigned version = 1; version <= 3; version++) {
        state->pgraph.surface_scale_factor = 3;
        NSData *wire = rb_wire(version);
        assert(pgraph_metal4_validate_report_snapshot(wire.bytes, wire.length));
        require([draw restoreReportSnapshot:wire error:&error], error);
        assert(state->pgraph.surface_scale_factor == (version == 1 ? 3u : 2u));
        rb_get(version);
        rb_process();
        rb_expect(version, version == 1 ? 4 : version == 2 ? 9 : 7);
        rb_cases++;
    }
    NSData *valid = rb_wire(3);
    require([draw restoreReportSnapshot:valid error:&error], error);
    NSData *canonical = [draw reportSnapshotWithError:&error];
    assert([canonical isEqualToData:valid]);
    for (NSUInteger n = 0; n < valid.length; n++) {
        assert(![draw
            restoreReportSnapshot:[valid subdataWithRange:NSMakeRange(0, n)]
                            error:NULL]);
        assert([[draw reportSnapshotWithError:&error] isEqualToData:canonical]);
        rb_rejects++;
    }
    const unsigned fields[] = { 0, 4, 12, 16, 20, 24, 44, 48, 52 };
    for (unsigned i = 0; i < ARRAY_SIZE(fields); i++) {
        NSMutableData *bad = [valid mutableCopy];
        stl_be_p((uint8_t *)bad.mutableBytes + fields[i],
                 fields[i] == 20 ? 0 : UINT32_MAX);
        assert(!pgraph_metal4_validate_report_snapshot(bad.bytes, bad.length));
        assert(![draw restoreReportSnapshot:bad error:NULL]);
        assert([[draw reportSnapshotWithError:&error] isEqualToData:canonical]);
        rb_rejects++;
    }
    NSMutableData *bad = [valid mutableCopy];
    uint8_t byte = 0;
    [bad appendBytes:&byte length:1];
    assert(![draw restoreReportSnapshot:bad error:NULL]);
    assert(![draw.reports getReport:2u << 24 error:NULL]);
    assert([[draw reportSnapshotWithError:&error] isEqualToData:canonical]);
    rb_rejects += 2;
    // v3 queued reports must own a closed prefix, never the live query.
    bad = [valid mutableCopy];
    bad.length = 52;
    stl_be_p((uint8_t *)bad.mutableBytes + 16, 1);
    stl_be_p((uint8_t *)bad.mutableBytes + 20, 0);
    stl_be_p((uint8_t *)bad.mutableBytes + 44, 1);
    stl_be_p((uint8_t *)bad.mutableBytes + 48, 0);
    rb_append32(bad, 0);
    rb_append32(bad, 1u << 24);
    rb_append32(bad, 1);
    rb_append32(bad, 0);
    assert(!pgraph_metal4_validate_report_snapshot(bad.bytes, bad.length));
    assert(![draw restoreReportSnapshot:bad error:NULL]);
    assert([[draw reportSnapshotWithError:&error] isEqualToData:canonical]);
    rb_rejects++;
    qemu_mutex_unlock(&state->pgraph.lock);
}

static void rb_legacy_active_tests(void)
{
    for (unsigned version = 1; version <= 2; version++)
        for (unsigned cleared = 0; cleared < 2; cleared++) {
            rb_fixture();
            NSError *error = nil;
            qemu_mutex_lock(&state->pgraph.lock);
            state->pgraph.surface_scale_factor = 2;
            NSMutableData *data = [NSMutableData new];
            const uint32_t h[] = { 0x4d345250, version, 0, 1, !cleared, 0, 2 };
            for (unsigned j = 0; j < (version == 1 ? 6u : 7u); j++)
                rb_append32(data, h[j]);
            rb_append64(data, 37);
            rb_append32(data, cleared ? 2 : 1);
            rb_append32(data,
                        0); // Active query used to belong only to report/clear.
            if (!cleared) {
                rb_append32(data, 0);
                rb_append32(data, 1u << 24);
                rb_append32(data, 1);
                rb_append32(data, 0);
            }
            NV2AMetalPGRAPHQuery *active = nil;
            assert(pgraph_metal4_validate_report_snapshot(data.bytes,
                                                          data.length));
            require([draw.reports restoreSnapshot:data
                                      activeQuery:&active
                                            error:&error],
                    error);
            assert(active && !active.discarded);
            rb_process();
            if (!cleared)
                rb_expect(0, 9);
            rb_counter(active, cleared ? 4 : 3);
            [draw.reports endQuery:active];
            rb_get(1);
            rb_process();
            rb_expect(1, cleared ? 1 : 10);
            qemu_mutex_unlock(&state->pgraph.lock);
            rb_cases++;
        }
}

static void report_boundary_tests(void)
{
    rb_fixture();
    NSError *error = nil;
    qemu_mutex_lock(&state->pgraph.lock);
    state->pgraph.zpass_pixel_count_enable = true;
    require([draw beginWithError:&error], error);
    require([draw flushDrawWithError:&error], error);
    rb_batch(3,
             3); // The flush caller starts the next independent common batch.
    rb_get(0);
    require([draw flushDrawWithError:&error], error);
    rb_batch(0, 0);
    rb_get(1);
    rb_process();
    rb_expect(0, 28); // Later GPU batches must not enter the earlier report.
    rb_expect(1, 34);
    require([draw endWithError:&error], error);
    rb_get(2);
    rb_process();
    rb_expect(2, 34);
    assert(state->pgraph.draw_time == 1);
    qemu_mutex_unlock(&state->pgraph.lock);
    groups++;
    rb_clear_tests();
    rb_pending_and_enable_tests();
    rb_failure_test();
    rb_rounding_tests();
    rb_snapshot_tests();
    rb_wire_tests();
    rb_legacy_active_tests();
    [draw.reports discard];
    printf("Metal report boundaries:%u cases/%u rejects;immutable live-Begin "
           "prefixes,FIFO/Clear,late "
           "failure/retry,pending/Current/enable,scale/uint32/uint64 "
           "wrap,cancel,v1/v2/v3 wire and active snapshot continuation PASS\n",
           rb_cases, rb_rejects);
}
#endif
