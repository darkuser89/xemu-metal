/* Original report subsection through QEMUFile/VMState; no VM or app.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#include "migration/savevm.h"

const VMStateDescription *test_metal_report_vmsd(void);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnull-pointer-subtraction"
static const VMStateField report_file_base[] = {
    VMSTATE_UINT32(pgraph.primitive_mode, NV2AState), VMSTATE_END_OF_LIST()
};
#pragma clang diagnostic pop

static VMStateDescription report_file_parent(void)
{
    static const VMStateDescription *sections[2];
    sections[0] = test_metal_report_vmsd();
    return (VMStateDescription){ .name = "nv2a",
                                 .version_id = 4,
                                 .minimum_version_id = 1,
                                 .fields = report_file_base,
                                 .subsections = sections };
}

static void report_file_u32(NSMutableData *data, uint32_t value)
{
    uint8_t bytes[4];
    stl_be_p(bytes, value);
    [data appendBytes:bytes length:sizeof(bytes)];
}

static NSMutableData *report_file_empty(unsigned version, unsigned scale)
{
    NSMutableData *data = [NSMutableData data];
    for (unsigned i = 0; i < 6; i++)
        report_file_u32(
            data, (uint32_t[]){ 0x4d345250, version, 0, 0, 0, UINT32_MAX }[i]);
    if (version >= 2)
        report_file_u32(data, scale);
    report_file_u32(data, 0);
    return data;
}

static NSMutableData *report_file_wire(NSData *payload, uint32_t primitive,
                                       bool enable)
{
    NSMutableData *data = [NSMutableData data];
    report_file_u32(data, primitive);
    const char *name = "nv2a/metal4-reports";
    uint8_t tag[2] = { QEMU_VM_SUBSECTION, strlen(name) };
    [data appendBytes:tag length:2];
    [data appendBytes:name length:strlen(name)];
    report_file_u32(data, 1);
    report_file_u32(data, payload.length);
    [data appendData:payload];
    uint8_t tail[2] = { enable, 0 };
    [data appendBytes:tail length:2];
    return data;
}

static void report_file_write(int fd, NSData *bytes)
{
    assert(ftruncate(fd, 0) == 0);
    assert(pwrite(fd, bytes.bytes, bytes.length, 0) == (ssize_t)bytes.length);
}

static NSData *report_file_read(int fd)
{
    struct stat st;
    assert(fstat(fd, &st) == 0 && st.st_size >= 0);
    NSMutableData *bytes = [NSMutableData dataWithLength:st.st_size];
    assert(pread(fd, bytes.mutableBytes, bytes.length, 0) ==
           (ssize_t)bytes.length);
    return bytes;
}

static void report_file_save(int fd, NV2AState *target)
{
    VMStateDescription parent = report_file_parent();
    QEMUFile *file = vertex_snapshot_file(fd, true);
    Error *error = NULL;
    assert(vmstate_save_state(file, &parent, target, NULL, &error) == 0 &&
           !error);
    qemu_put_byte(file, 0);
    assert(qemu_fclose(file) == 0);
}

static int report_file_load(int fd, NV2AState *target)
{
    VMStateDescription parent = report_file_parent();
    QEMUFile *file = vertex_snapshot_file(fd, false);
    Error *error = NULL;
    int result = vmstate_load_state(file, &parent, target, 4, &error);
    if (!result)
        result = qemu_file_get_error(file);
    error_free(error);
    qemu_fclose(file);
    return result;
}

static void report_file_host_tests(void)
{
    const VMStateDescription *section = test_metal_report_vmsd();
    assert(!strcmp(section->name, "nv2a/metal4-reports") &&
           section->version_id == 1 && section->minimum_version_id == 1 &&
           section->post_load && section->needed);
    assert(section->fields[0].offset ==
           offsetof(NV2AState, pgraph.metal4_report_snapshot_size));
    assert(
        (section->fields[1].flags & (VMS_POINTER | VMS_ALLOC | VMS_VBUFFER)) ==
        (VMS_POINTER | VMS_ALLOC | VMS_VBUFFER));
    int fd = new_vertex_snapshot_file();
    NV2AState *source = g_new0(NV2AState, 1);
    NV2AState *target = g_new0(NV2AState, 1);
    PGRAPHRenderer metal = { .type = CONFIG_DISPLAY_RENDERER_METAL4 };
    source->pgraph.renderer = &metal;
    unsigned valid = 0, rejected = 0, omitted = 0;
    for (unsigned version = 1; version <= 3; version++) {
        for (unsigned scale_index = 0; scale_index < 4; scale_index++) {
            unsigned scale = (unsigned[]){ 1, 2, 3, 16384 }[scale_index];
            for (unsigned enable = 0; enable < 2; enable++) {
                NSData *payload = report_file_empty(version, scale);
                source->pgraph.primitive_mode = PRIM_TYPE_INVALID;
                source->pgraph.metal4_report_snapshot =
                    (uint8_t *)payload.bytes;
                source->pgraph.metal4_report_snapshot_size = payload.length;
                source->pgraph.zpass_pixel_count_enable = enable;
                assert(section->needed(source));
                report_file_save(fd, source);
                NSData *wire =
                    report_file_wire(payload, PRIM_TYPE_INVALID, enable);
                assert([report_file_read(fd) isEqualToData:wire]);
                memset(target, 0, sizeof(*target));
                target->pgraph.surface_scale_factor = 7;
                assert(report_file_load(fd, target) == 0);
                assert(target->pgraph.metal4_report_snapshot_size ==
                           payload.length &&
                       !memcmp(target->pgraph.metal4_report_snapshot,
                               payload.bytes, payload.length));
                assert(target->pgraph.zpass_pixel_count_enable == enable &&
                       target->pgraph.primitive_mode == PRIM_TYPE_INVALID &&
                       target->pgraph.surface_scale_factor ==
                           (version == 2 ? scale : 7));
                g_free(target->pgraph.metal4_report_snapshot);
                valid++;
            }
        }
    }
    for (unsigned version = 1; version <= 3; version++) {
        NSMutableData *payload = report_file_empty(version, 2);
        [payload setLength:version == 1 ? 24 : 28];
        stl_be_p((uint8_t *)payload.mutableBytes + 12, 1);
        stl_be_p((uint8_t *)payload.mutableBytes + 20, 0);
        report_file_u32(payload, 0);
        report_file_u32(payload, 0);
        if (version == 3) {
            report_file_u32(payload, 0);
            report_file_u32(payload, 0);
        }
        report_file_u32(payload, 1);
        report_file_u32(payload, 1);
        report_file_u32(payload, 0);
        assert(pgraph_metal4_validate_report_snapshot(payload.bytes,
                                                      payload.length));
        for (unsigned open = 0; open < 2; open++) {
            report_file_write(fd, report_file_wire(payload,
                                                   open ? PRIM_TYPE_TRIANGLES :
                                                          PRIM_TYPE_INVALID,
                                                   true));
            memset(target, 0, sizeof(*target));
            target->pgraph.surface_scale_factor = 7;
            int result = report_file_load(fd, target);
            if (open) {
                assert(result == 0 &&
                       target->pgraph.primitive_mode == PRIM_TYPE_TRIANGLES);
                valid++;
            } else {
                assert(result < 0 && target->pgraph.surface_scale_factor == 7);
                rejected++;
            }
            g_free(target->pgraph.metal4_report_snapshot);
        }
    }
    for (unsigned mode = 0; mode < 3; mode++) {
        NSData *payload = report_file_empty(3, 1);
        PGRAPHRenderer other = { .type = CONFIG_DISPLAY_RENDERER_NULL };
        source->pgraph.renderer = mode == 0 ? NULL :
                                  mode == 1 ? &other :
                                              &metal;
        source->pgraph.metal4_report_snapshot = (uint8_t *)payload.bytes;
        source->pgraph.metal4_report_snapshot_size =
            mode == 2 ? 0 : payload.length;
        assert(!section->needed(source));
        report_file_save(fd, source);
        NSMutableData *expected = [NSMutableData data];
        report_file_u32(expected, PRIM_TYPE_INVALID);
        uint8_t eof = 0;
        [expected appendBytes:&eof length:1];
        assert([report_file_read(fd) isEqualToData:expected]);
        memset(target, 0, sizeof(*target));
        assert(report_file_load(fd, target) == 0 &&
               !target->pgraph.metal4_report_snapshot &&
               !target->pgraph.metal4_report_snapshot_size &&
               !target->pgraph.zpass_pixel_count_enable);
        omitted++;
    }
    const unsigned size_offset = 4 + 2 + strlen(section->name) + 4;
    for (unsigned test = 0; test < 12; test++) {
        NSMutableData *payload = report_file_empty(3, 2);
        switch (test) {
        case 0:
            stl_be_p(payload.mutableBytes, 0);
            break;
        case 1:
            stl_be_p((uint8_t *)payload.mutableBytes + 4, 0);
            break;
        case 2:
            stl_be_p((uint8_t *)payload.mutableBytes + 4, 4);
            break;
        case 3:
            stl_be_p((uint8_t *)payload.mutableBytes + 24, 0);
            break;
        case 4:
            stl_be_p((uint8_t *)payload.mutableBytes + 24, 16385);
            break;
        case 5:
            stl_be_p((uint8_t *)payload.mutableBytes + 12, 1);
            break;
        case 6:
            stl_be_p((uint8_t *)payload.mutableBytes + 16, 1);
            break;
        case 7:
            stl_be_p((uint8_t *)payload.mutableBytes + 20, 0);
            break;
        case 8:
            stl_be_p((uint8_t *)payload.mutableBytes + 28, 1);
            break;
        case 9:
            report_file_u32(payload, 0);
            break;
        case 10:
            [payload setLength:0];
            break;
        case 11:
            [payload setLength:24];
            break;
        }
        assert(!pgraph_metal4_validate_report_snapshot(payload.bytes,
                                                       payload.length));
        report_file_write(fd,
                          report_file_wire(payload, PRIM_TYPE_INVALID, true));
        memset(target, 0, sizeof(*target));
        target->pgraph.surface_scale_factor = 7;
        assert(report_file_load(fd, target) < 0 &&
               target->pgraph.surface_scale_factor == 7);
        g_free(target->pgraph.metal4_report_snapshot);
        rejected++;
    }
    for (unsigned i = 0; i < 2; i++) {
        NSMutableData *wire =
            report_file_wire(report_file_empty(3, 1), PRIM_TYPE_INVALID, true);
        stl_be_p((uint8_t *)wire.mutableBytes + size_offset,
                 i ? UINT32_MAX : 64u * 1024 * 1024 + 1);
        report_file_write(fd, wire);
        memset(target, 0, sizeof(*target));
        target->pgraph.metal4_report_snapshot_size = 123;
        assert(report_file_load(fd, target) < 0 &&
               !target->pgraph.metal4_report_snapshot &&
               target->pgraph.metal4_report_snapshot_size == 123 &&
               !target->pgraph.zpass_pixel_count_enable);
        rejected++;
    }
    for (unsigned version = 0; version <= 2; version += 2) {
        NSMutableData *wire =
            report_file_wire(report_file_empty(3, 1), PRIM_TYPE_INVALID, true);
        stl_be_p((uint8_t *)wire.mutableBytes + size_offset - 4, version);
        report_file_write(fd, wire);
        memset(target, 0, sizeof(*target));
        assert(report_file_load(fd, target) < 0 &&
               !target->pgraph.metal4_report_snapshot);
        rejected++;
    }
    /* Once the complete subsection header selects the original descriptor,
     * every short size, payload, and bool must fail rather than publish state.
     */
    NSData *wire =
        report_file_wire(report_file_empty(3, 1), PRIM_TYPE_INVALID, true);
    for (NSUInteger cut = size_offset; cut < wire.length - 1; cut++) {
        report_file_write(fd, [wire subdataWithRange:NSMakeRange(0, cut)]);
        memset(target, 0, sizeof(*target));
        assert(report_file_load(fd, target) < 0);
        g_free(target->pgraph.metal4_report_snapshot);
        rejected++;
    }
    /* Check the inclusive decoder bound without allocating a 64 MiB VBUFFER. */
    for (unsigned i = 0; i < 3; i++) {
        NSMutableData *bytes = [NSMutableData data];
        uint32_t expected = (uint32_t[]){ 0, 1, 64u * 1024 * 1024 }[i];
        report_file_u32(bytes, expected);
        report_file_write(fd, bytes);
        QEMUFile *file = vertex_snapshot_file(fd, false);
        uint32_t value = UINT32_MAX;
        assert(section->fields[0].info->get(file, &value, sizeof(value),
                                            &section->fields[0]) == 0 &&
               value == expected && !qemu_file_get_error(file));
        assert(qemu_fclose(file) == 0);
    }
    close(fd);
    g_free(source);
    g_free(target);
    printf(
        "Report VMState file: %u v1/v2/v3 roundtrips (24 byte-exact saves,3 "
        "open-query loads), %u omitted "
        "subsections, %u malformed/truncated/version/oversize rejections; "
        "oversize rejected before VBUFFER allocation;3 decoder bounds PASS\n",
        valid, omitted, rejected);
}

static void report_file_gpu_tests(void)
{
    unsigned cases = 0;
    for (unsigned saved_scale = 1; saved_scale <= 3; saved_scale++) {
        for (unsigned live_scale = 1; live_scale <= 3; live_scale++) {
            fixture();
            state->pgraph.surface_scale_factor = saved_scale;
            send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
            query_triangle(0);
            get_report(0);
            process_reports();
            begin(PRIM_TYPE_TRIANGLES);
            arrays(3, 3);
            qemu_mutex_lock(&state->pgraph.lock);
            renderer.ops.flush_draw(state);
            qemu_mutex_unlock(&state->pgraph.lock);
            state->pgraph.draw_arrays_length = 0;
            get_report(16);
            renderer.ops.pre_savevm_trigger(state);
            process_pending();
            renderer.ops.pre_savevm_wait(state);
            assert(state->pgraph.metal4_report_snapshot &&
                   ldl_be_p(state->pgraph.metal4_report_snapshot + 4) == 3);
            int fd = new_vertex_snapshot_file();
            report_file_save(fd, state);
            before_ram_load();
            state->pgraph.surface_scale_factor = live_scale;
            g_config.display.quality.surface_scale = live_scale;
            state->pgraph.primitive_mode = PRIM_TYPE_INVALID;
            state->pgraph.zpass_pixel_count_enable = false;
            assert(report_file_load(fd, state) == 0 &&
                   state->pgraph.primitive_mode == PRIM_TYPE_TRIANGLES &&
                   state->pgraph.zpass_pixel_count_enable);
            after_ram_load();
            assert(state->pgraph.surface_scale_factor == saved_scale &&
                   g_config.display.quality.surface_scale == (int)live_scale);
            arrays(0, 3);
            end();
            get_report(32);
            process_reports();
            unsigned large = 8 * saved_scale, small = 4 * saved_scale;
            unsigned large_count = large * (large - 1) / 2;
            unsigned small_count = small * (small - 1) / 2;
            unsigned divisor = saved_scale * saved_scale;
            assert(report_result(16) ==
                   large_count / divisor + small_count / divisor);
            assert(report_result(32) ==
                   large_count / divisor +
                       (small_count + large_count) / divisor);
            close(fd);
            cases++;
        }
    }
    printf("Report VMState GPU: %u actual v3 file saves/loads, open-query "
           "continuation and exact pending/following counts at saved/live "
           "scales1..3;host UI scale retained PASS\n",
           cases);
    for (unsigned version = 1; version <= 3; version++) {
        fixture();
        before_ram_load();
        state->pgraph.surface_scale_factor = 3;
        g_config.display.quality.surface_scale = 3;
        int fd = new_vertex_snapshot_file();
        report_file_write(fd, report_file_wire(report_file_empty(version, 2),
                                               PRIM_TYPE_INVALID, false));
        assert(report_file_load(fd, state) == 0);
        after_ram_load();
        unsigned scale = version == 1 ? 3 : 2;
        assert(state->pgraph.surface_scale_factor == scale &&
               g_config.display.quality.surface_scale == 3 &&
               !state->pgraph.zpass_pixel_count_enable);
        query_triangle(0);
        get_report(0);
        process_reports();
        assert(report_result(0) == 0);
        send_method(NV097_SET_ZPASS_PIXEL_COUNT_ENABLE, 1);
        query_triangle(0);
        get_report(16);
        process_reports();
        unsigned n = 8 * scale;
        assert(report_result(16) == n * (n - 1) / 2 / (scale * scale));
        close(fd);
    }
    puts("Report VMState compatibility:3 v1/v2/v3 file loads through actual "
         "Metal restore;legacy/live versus saved scale,disabled/enabled "
         "query counts exact PASS");
}

static void report_file_tests(void)
{
    report_file_host_tests();
    report_file_gpu_tests();
    groups++;
}
