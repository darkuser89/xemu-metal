/* Native XF upload and WriteEnable restore regression.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnull-pointer-subtraction"
static const VMStateField xf_restore_fields[] = {
    VMSTATE_UINT32_ARRAY(pgraph.regs_, NV2AState, 0x2000),
    VMSTATE_UINT32_ARRAY(pgraph.vertex_state_shader_v0, NV2AState, 4),
    VMSTATE_UINT32_2DARRAY(pgraph.program_data, NV2AState,
                           NV2A_MAX_TRANSFORM_PROGRAM_LENGTH, VSH_TOKEN_SIZE),
    VMSTATE_UINT32_2DARRAY(pgraph.vsh_constants, NV2AState,
                           NV2A_VERTEXSHADER_CONSTANTS, 4),
    VMSTATE_BOOL_ARRAY(pgraph.vsh_constants_dirty, NV2AState,
                       NV2A_VERTEXSHADER_CONSTANTS),
    VMSTATE_END_OF_LIST()
};
#pragma clang diagnostic pop

static void xf_upload_restore(void)
{
    /* Match the production base XF fields; WriteEnable must come from the
     * actual native subsection, never from a fixture-only base field. */
    VMStateDescription parent = array_snapshot_parent;
    unsigned base = 0;
    while (parent.fields[base].name)
        base++;
    VMStateField *fields =
        g_new(VMStateField, base + ARRAY_SIZE(xf_restore_fields));
    memcpy(fields, parent.fields, base * sizeof(*fields));
    memcpy(fields + base, xf_restore_fields, sizeof(xf_restore_fields));
    parent.fields = fields;
    unsigned cases = 0;
    for (unsigned location = 0; location < 2; location++)
        for (unsigned active = 0; active < 2; active++)
            for (unsigned nop = 0; nop < 2; nop++)
                for (unsigned writes = 0; writes < 2; writes++)
                    for (unsigned order = 0; order < 2; order++)
                        for (unsigned pc = 1; pc < 4; pc++)
                            for (unsigned cc = 1; cc < 4; cc++) {
                                fixture();
                                PGRAPHState *pg = &state->pgraph;
                                unsigned start = location ? 133 : 0;
                                unsigned row = location ? 191 : 96;
                                send_method(NV097_SET_TRANSFORM_EXECUTION_MODE,
                                            2 | 1u << 2);
                                send_method(NV097_SET_TRANSFORM_PROGRAM_START,
                                            start);
                                send_method(
                                    NV097_SET_TRANSFORM_PROGRAM_CXT_WRITE_EN,
                                    writes);
                                state_tokens(start, 190, YES);
                                memset(pg->vsh_constants[190], 0, 16);
                                memset(pg->vsh_constants[row], 0, 16);
                                if (nop)
                                    send_method(NV097_SET_COLOR_MASK, 0);
                                if (active) {
                                    begin(PRIM_TYPE_TRIANGLES);
                                    arrays(0, 3);
                                }
                                Token replacement = token(3, 0, row);
                                source(&replacement, 0, 3, 0, 0xe4);
                                source(&replacement, 2, 2, 0, 0xe4);
                                destination(&replacement, row, 15, 0, 0, 0, 0);
                                const float initial[] = { 1, 2, 4, 8 };
                                for (unsigned phase = 0; phase < 2; phase++) {
                                    if (phase == order) {
                                        send_method(
                                            NV097_SET_TRANSFORM_PROGRAM_LOAD,
                                            start);
                                        for (unsigned k = 0; k < pc; k++)
                                            send_method(
                                                NV097_SET_TRANSFORM_PROGRAM +
                                                    k * 4,
                                                replacement.word[k]);
                                    } else {
                                        send_method(
                                            NV097_SET_TRANSFORM_CONSTANT_LOAD,
                                            row);
                                        for (unsigned k = 0; k < cc; k++)
                                            send_float_method(
                                                NV097_SET_TRANSFORM_CONSTANT +
                                                    k * 4,
                                                initial[k]);
                                    }
                                }
                                renderer.ops.pre_savevm_trigger(state);
                                process_pending();
                                renderer.ops.pre_savevm_wait(state);
                                int fd = new_vertex_snapshot_file();
                                NSData *regs =
                                    [NSData dataWithBytes:pg->regs_
                                                   length:sizeof(pg->regs_)];
                                NSData *program = [NSData
                                    dataWithBytes:pg->program_data
                                           length:sizeof(pg->program_data)];
                                NSData *constants = [NSData
                                    dataWithBytes:pg->vsh_constants
                                           length:sizeof(pg->vsh_constants)];
                                NSData *dirty = [NSData
                                    dataWithBytes:pg->vsh_constants_dirty
                                           length:sizeof(
                                                      pg->vsh_constants_dirty)];
                                const uint32_t launch[4] = { 1, 2, 3, 4 };
                                /* LAUNCH_DATA is part of the base serializer.
                                 */
                                memcpy(pg->vertex_state_shader_v0, launch, 16);
                                save_snapshot_parent(fd, &parent);
                                before_ram_load();
                                memset(pg->regs_, 0xa5, sizeof(pg->regs_));
                                memset(pg->program_data, 0xff,
                                       sizeof(pg->program_data));
                                memset(pg->vsh_constants, 0xff,
                                       sizeof(pg->vsh_constants));
                                memset(pg->vsh_constants_dirty, 0,
                                       sizeof(pg->vsh_constants_dirty));
                                memset(pg->vertex_state_shader_v0, 0, 16);
                                pg->enable_vertex_program_write = !writes;
                                assert(load_snapshot_parent(fd, &parent) == 0);
                                close(fd);
                                if (pg->enable_vertex_program_write != writes) {
                                    fprintf(stderr,
                                            "XF restore WriteEnable: got %u, "
                                            "expected %u (idle=%u)\n",
                                            pg->enable_vertex_program_write,
                                            writes, !active);
                                    exit(1);
                                }
                                assert(!memcmp(pg->regs_, regs.bytes,
                                               regs.length));
                                assert(!memcmp(pg->program_data, program.bytes,
                                               program.length));
                                assert(!memcmp(pg->vsh_constants,
                                               constants.bytes,
                                               constants.length));
                                assert(!memcmp(pg->vsh_constants_dirty,
                                               dirty.bytes, dirty.length));
                                assert(!memcmp(pg->vertex_state_shader_v0,
                                               launch, 16));
                                after_ram_load();
                                for (unsigned k = pc; k < 4; k++)
                                    send_method(NV097_SET_TRANSFORM_PROGRAM +
                                                    k * 4,
                                                replacement.word[k]);
                                for (unsigned k = cc; k < 4; k++)
                                    send_float_method(
                                        NV097_SET_TRANSFORM_CONSTANT + k * 4,
                                        initial[k]);
                                if (active)
                                    end();
                                assert(state_constant(190, 3) ==
                                       (active && writes ? 3 : 0));
                                assert(state_constant(row, 3) == 8);
                                begin(PRIM_TYPE_TRIANGLES);
                                arrays(0, 3);
                                end();
                                const float sum[] = { 8, 8, 98304, 3 };
                                for (unsigned k = 0; k < 4; k++)
                                    assert(state_constant(row, k) ==
                                           initial[k] + (writes ? sum[k] : 0));
                                assert(state_constant(190, 3) ==
                                       (active && writes ? 3 : 0));
                                assert(color(1, 1) ==
                                       (nop ? 0xffff0000 : 0xff00ff00));
                                cases++;
                            }
    g_free(fields);
    assert(cases == 288);
    groups++;
    puts("XF upload restore:288 idle/active, WriteEnable0/1, raw/raster, "
         "program0/133, constant96/191, both upload orders and all1..3 "
         "word cuts; poisoned base XF fields restored, completed uploads "
         "execute natively with exact constant feedback and pixels PASS");
}
