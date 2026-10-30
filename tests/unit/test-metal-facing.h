/* PGRAPH orientation parity with OGL's SETUPRASTER mapping. No VM or window.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_FACING_H
#define TEST_METAL_FACING_H

static void pgraph_facing_parity(void)
{
    unsigned cases = 0, restored = 0, pixels = 0;
    const unsigned primitives[] = {
        PRIM_TYPE_TRIANGLES, PRIM_TYPE_TRIANGLE_STRIP, PRIM_TYPE_TRIANGLE_FAN,
        PRIM_TYPE_QUADS,     PRIM_TYPE_QUAD_STRIP,     PRIM_TYPE_POLYGON
    };
    const unsigned modes[] = { NV097_SET_FRONT_POLYGON_MODE_V_FILL,
                               NV097_SET_FRONT_POLYGON_MODE_V_POINT,
                               NV097_SET_FRONT_POLYGON_MODE_V_LINE };
    for (unsigned programmed = 0; programmed < 2; programmed++)
        for (unsigned primitiveIndex = 0; primitiveIndex < 6; primitiveIndex++)
            for (unsigned reverse = 0; reverse < 2; reverse++)
                for (unsigned guestCCW = 0; guestCCW < 2; guestCCW++)
                    for (unsigned cull = 0; cull < 4; cull++)
                        for (unsigned mode = 0; mode < 3; mode++)
                            for (unsigned operation = 0; operation < 5;
                                 operation++) {
                                unsigned primitive = primitives[primitiveIndex];
                                /* OGL and this backend do not implement POLYGON
                                 * point mode. */
                                if (primitive == PRIM_TYPE_POLYGON && mode != 2)
                                    continue;
                                fixture();
                                PGRAPHState *pg = &state->pgraph;
                                const float front[] = { 0, 1, 0, 1 };
                                const float back[] = { 1, 0, 0, 1 };
                                pg->material_alpha = pg->material_alpha_back =
                                    1;
                                send_method(NV097_SET_LIGHT_TWO_SIDE_ENABLE, 1);
                                send_method(NV097_SET_FRONT_FACE,
                                            guestCCW ?
                                                NV097_SET_FRONT_FACE_V_CCW :
                                                NV097_SET_FRONT_FACE_V_CW);
                                send_method(NV097_SET_CULL_FACE_ENABLE, !!cull);
                                if (cull)
                                    send_method(
                                        NV097_SET_CULL_FACE,
                                        cull == 1 ?
                                            NV097_SET_CULL_FACE_V_FRONT :
                                        cull == 2 ?
                                            NV097_SET_CULL_FACE_V_BACK :
                                            NV097_SET_CULL_FACE_V_FRONT_AND_BACK);
                                send_method(NV097_SET_FRONT_POLYGON_MODE,
                                            modes[mode]);
                                send_method(NV097_SET_BACK_POLYGON_MODE,
                                            modes[(mode + 1) % 3]);
                                send_method(NV097_SET_POINT_SIZE, 8);
                                if (programmed) {
                                    pg->regs_[NV_PGRAPH_CSV0_D] =
                                        2u << 30 | NV_PGRAPH_CSV0_D_RANGE_MODE;
                                    const unsigned outputs[] = { 0, 3, 7 };
                                    for (unsigned slot = 0; slot < 3; slot++) {
                                        pg->program_data[slot][1] =
                                            1 << 21 |
                                            (slot ? (slot + 4) << 13 : 0) | 27;
                                        pg->program_data[slot][2] =
                                            (slot ? 3u : 2u) << 26;
                                        pg->program_data[slot][3] =
                                            1 << 11 | outputs[slot] << 3 |
                                            15 << 12 | (slot == 2);
                                    }
                                    memcpy(pg->vsh_constants[5], front,
                                           sizeof(front));
                                    memcpy(pg->vsh_constants[6], back,
                                           sizeof(back));
                                } else {
                                    send_method(NV097_SET_LIGHTING_ENABLE, 1);
                                    memcpy(
                                        pg->ltctxa[NV_IGRAPH_XF_LTCTXA_FR_AMB],
                                        front, 12);
                                    memcpy(
                                        pg->ltctxa[NV_IGRAPH_XF_LTCTXA_BR_AMB],
                                        back, 12);
                                }
                                BOOL strip =
                                    primitive == PRIM_TYPE_TRIANGLE_STRIP ||
                                    primitive == PRIM_TYPE_QUAD_STRIP;
                                unsigned count =
                                    primitive == PRIM_TYPE_TRIANGLES ? 3 : 4;
                                const float xy[4][2] = {
                                    { 1, 1 }, { 7, 1 }, { 7, 7 }, { 1, 7 }
                                };
                                const unsigned triangle[3] = { 0, 1, 3 };
                                const unsigned stripOrder[4] = { 0, 1, 3, 2 };
                                float positions[4][4] = { 0 };
                                for (unsigned i = 0; i < count; i++) {
                                    unsigned index = count == 3 ? triangle[i] :
                                                     strip ? stripOrder[i] :
                                                             i;
                                    if (reverse) {
                                        if (strip)
                                            index = stripOrder[i ^ 1];
                                        else if (i)
                                            index = count == 3 ?
                                                        triangle[3 - i] :
                                                        4 - i;
                                    }
                                    positions[i][0] = xy[index][0];
                                    positions[i][1] = xy[index][1];
                                    positions[i][2] = 32768;
                                    positions[i][3] = 1;
                                }
                                cpu_write(16384, sizeof(positions));
                                memcpy(state->vram_ptr + 16384, positions,
                                       sizeof(positions));
                                cpu_write(1024, 256);
                                for (unsigned i = 0; i < 64; i++)
                                    stl_le_p(state->vram_ptr + 1024 + i * 4,
                                             0xff0000ff);
                                begin(primitive);
                                NSError *error = nil;
                                NSData *snapshot =
                                    [draw beginSnapshotWithError:&error];
                                require(snapshot != nil, error);
                                assert(
                                    (ldl_be_p((const uint8_t *)snapshot.bytes +
                                              32) &
                                     1) == guestCCW);
                                NSData *vertex = draw.vertexSnapshot;
                                if (operation) {
                                    send_method(NV097_SET_FRONT_FACE,
                                                guestCCW ?
                                                    NV097_SET_FRONT_FACE_V_CW :
                                                    NV097_SET_FRONT_FACE_V_CCW);
                                    send_method(NV097_SET_CULL_FACE_ENABLE, 1);
                                    send_method(
                                        NV097_SET_CULL_FACE,
                                        NV097_SET_CULL_FACE_V_FRONT_AND_BACK);
                                    send_method(NV097_SET_FRONT_POLYGON_MODE,
                                                modes[0]);
                                    send_method(NV097_SET_BACK_POLYGON_MODE,
                                                modes[0]);
                                }
                                if (operation >= 2) {
                                    unsigned version = operation - 1;
                                    const uint8_t *bytes = snapshot.bytes;
                                    NSUInteger pixelSize = ldl_be_p(bytes + 40);
                                    NSUInteger textureSize =
                                        ldl_be_p(bytes + 44);
                                    NSMutableData *old;
                                    if (version == 1) {
                                        old = [[snapshot
                                            subdataWithRange:NSMakeRange(0, 44)]
                                            mutableCopy];
                                        [old
                                            appendData:[snapshot
                                                           subdataWithRange:
                                                               NSMakeRange(
                                                                   48,
                                                                   pixelSize)]];
                                    } else if (version == 2) {
                                        old = [[snapshot
                                            subdataWithRange:
                                                NSMakeRange(0, 48 + pixelSize +
                                                                   textureSize)]
                                            mutableCopy];
                                    } else
                                        old = [snapshot mutableCopy];
                                    stl_be_p((uint8_t *)old.mutableBytes + 4,
                                             version);
                                    assert(pgraph_metal4_validate_begin_capture(
                                        old.bytes, old.length));
                                    qemu_mutex_lock(&pg->lock);
                                    [draw invalidateSession];
                                    require([draw restoreVertexSnapshot:vertex
                                                                  error:&error],
                                            error);
                                    require([draw restoreBeginSnapshot:old
                                                                 error:&error],
                                            error);
                                    require([draw beginWithError:&error],
                                            error);
                                    qemu_mutex_unlock(&pg->lock);
                                    restored++;
                                }
                                arrays(0, count);
                                end();
                                /* GL uses positive guest screen Y and CW for
                                 * the CCW bit; opposite input orders therefore
                                 * have opposite source faces. */
                                BOOL frontFace = reverse == guestCCW;
                                BOOL culled =
                                    cull == 3 ||
                                    (frontFace ? cull == 1 : cull == 2);
                                uint32_t expected =
                                    frontFace ? 0xff00ff00 : 0xffff0000;
                                unsigned covered = 0;
                                for (unsigned y = 0; y < 8; y++)
                                    for (unsigned x = 0; x < 8; x++) {
                                        uint32_t value = color(x, y);
                                        if (value != 0xff0000ff) {
                                            if (culled || value != expected) {
                                                fprintf(
                                                    stderr,
                                                    "PGRAPH facing program%u "
                                                    "primitive%u reverse%u "
                                                    "ccw%u cull%u mode%u "
                                                    "operation%u pixel%u,%u "
                                                    "got%08x expected%08x "
                                                    "culled%u\n",
                                                    programmed, primitive,
                                                    reverse, guestCCW, cull,
                                                    mode, operation, x, y,
                                                    value, expected, culled);
                                                abort();
                                            }
                                            covered++;
                                        }
                                        pixels++;
                                    }
                                assert(culled || covered);
                                cases++;
                            }
    assert(cases == 2560 && restored == 1536 && pixels == 163840);
    groups++;
    printf("PGRAPH facing: %u fixed/programmed "
           "topology/winding/cull/mixed-mode/Begin cases, %u version1/2/3 "
           "restores, %u exact pixels PASS\n",
           cases, restored, pixels);
}
#endif
