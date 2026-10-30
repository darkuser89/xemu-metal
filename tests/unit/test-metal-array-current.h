/* Current values after unsorted closed DrawArrays and following immediate
 * input. Actual native fetch/raster and production vertex VMState subsection;
 * only the outer VM/RAM loading is simulated. No application, VM or window
 * starts. SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef TEST_METAL_ARRAY_CURRENT_H
#define TEST_METAL_ARRAY_CURRENT_H

static void array_current_check(const float expected[16][4])
{
    for (unsigned attribute = 1; attribute < 16; attribute++)
        assert(!memcmp(state->pgraph.vertex_attributes[attribute].inline_value,
                       expected[attribute], 16));
}

static void array_current_red(void)
{
    cpu_write(1024, 256);
    for (unsigned pixel = 0; pixel < 64; pixel++) {
        uint32_t red = 0xffff0000;
        memcpy(state->vram_ptr + 1024 + pixel * 4, &red, 4);
    }
}

static void array_current_restore(void)
{
    const unsigned lengths[] = { 2, 4, 16 };
    unsigned cases = 0, restores = 0, nonlast = 0, words = 0;
    unsigned formats = 0;
    for (unsigned lengthIndex = 0; lengthIndex < ARRAY_SIZE(lengths);
         lengthIndex++) {
        unsigned length = lengths[lengthIndex];
        for (unsigned rotation = 0; rotation < length; rotation++)
            for (unsigned kindShift = 0; kindShift < 6; kindShift++)
                for (unsigned mode = 0; mode < 3; mode++)
                    @autoreleasepool {
                        fixture();
                        PGRAPHState *pg = &state->pgraph;
                        unsigned mask = (rotation + kindShift) & 7;
                        w_mixed_attributes(kindShift, 0, mask);
                        unsigned maximum = length * 3 - 1;
                        /* The visible diffuse current deliberately differs
                         * from all lower ranges. Other active attributes use
                         * all six typed decoders and the independent oracle. */
                        VertexAttribute *diffuse = &pg->vertex_attributes[3];
                        diffuse->format =
                            NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
                        diffuse->size = 4;
                        diffuse->count = 4;
                        diffuse->stride = 16;
                        diffuse->offset = 12288;
                        cpu_write(16384, length * 3 * 16);
                        cpu_write(28672, length * 3 * 16);
                        const float triangle[3][4] = {
                            { 0, 0, 32768, 1 },
                            { 8, 0, 32768, 1 },
                            { 0, 8, 32768, 1 },
                        };
                        for (unsigned index = 0; index <= maximum; index++) {
                            memcpy(state->vram_ptr + 16384 + index * 16,
                                   triangle[index % 3], 16);
                            float diffuseValue[4] = { 0, index == maximum,
                                                      index != maximum, 1 };
                            memcpy(state->vram_ptr + 28672 + index * 16,
                                   diffuseValue, 16);
                        }
                        float expected[16][4] = { 0 };
                        memcpy(expected[0], triangle[2], 16);
                        for (unsigned attribute = 1; attribute < 16;
                             attribute++) {
                            if (attribute == 3) {
                                expected[attribute][1] =
                                    expected[attribute][3] = 1;
                                continue;
                            }
                            unsigned kind =
                                w_mixed_attribute_kind(attribute, kindShift, 0);
                            unsigned count =
                                w_mixed_attribute_count(attribute, kind, mask);
                            w_mixed_current_expected(attribute, maximum, kind,
                                                     count, mask,
                                                     expected[attribute]);
                            formats |= 1u << kind;
                        }
                        /* Every possible final range is exercised, with
                         * nonmonotonic order for lengths4/16. Logical End/Begin
                         * boundaries use the actual common lookahead path. */
                        unsigned multiplier = length == 16 ? 7 :
                                              length == 4  ? 3 :
                                                             1;
                        begin(PRIM_TYPE_TRIANGLES);
                        for (unsigned range = 0; range + 1 < length; range++) {
                            unsigned first =
                                ((range * multiplier + rotation) % length) * 3;
                            unsigned next =
                                (((range + 1) * multiplier + rotation) %
                                 length) *
                                3;
                            uint32_t params[] = { first | 2u << 24,
                                                  NV097_SET_BEGIN_END,
                                                  0,
                                                  NV097_SET_BEGIN_END,
                                                  PRIM_TYPE_TRIANGLES,
                                                  NV097_DRAW_ARRAYS,
                                                  next | 2u << 24,
                                                  0 };
                            assert(method(NV097_DRAW_ARRAYS, params[0], params,
                                          1, 7, false) == 5);
                        }
                        unsigned final =
                            (((length - 1) * multiplier + rotation) % length) *
                            3;
                        arrays(final, 3);
                        assert(pg->draw_arrays_length == length &&
                               pg->draw_arrays_min_start == 0 &&
                               pg->draw_arrays_max_count == maximum + 1);
                        end();
                        /* OGL uses max_count-1 for arrays, unlike the last
                         * explicitly submitted inline element. This is an
                         * OGL/native parity check, not Xbox legality proof. */
                        assert(!memcmp(pg->vertex_attributes[0].inline_value,
                                       expected[0], 16));
                        array_current_check(expected);
                        assert(pg->draw_time == 1);
                        if (final + 2 != maximum)
                            nonlast++;
                        array_current_red();
                        int fd = -1;
                        if (mode == 1) {
                            fd = new_vertex_snapshot_file();
                            save_vertex_snapshot(fd);
                        }
                        begin(PRIM_TYPE_TRIANGLES);
                        inline_position(0, 0);
                        inline_position(8, 0);
                        if (mode == 2) {
                            fd = new_vertex_snapshot_file();
                            save_vertex_snapshot(fd);
                        }
                        if (mode) {
                            /* Finish/alter the live branch after saving. */
                            inline_position(0, 8);
                            end();
                            before_ram_load();
                            for (unsigned attribute = 0; attribute < 16;
                                 attribute++) {
                                memset(pg->vertex_attributes[attribute]
                                           .inline_value,
                                       0xa5, 16);
                                pg->vertex_attributes[attribute].count = 0;
                                pg->vertex_attributes[attribute]
                                    .inline_buffer_populated = false;
                            }
                            /* New source RAM must not replace restored Current.
                             */
                            memset(state->vram_ptr + 28672, 0, length * 3 * 16);
                            assert(load_vertex_snapshot(fd) == 0);
                            after_ram_load();
                            array_current_red();
                            assert(color(1, 1) == 0xffff0000);
                            array_current_check(expected);
                            assert(pg->primitive_mode ==
                                   (mode == 2 ? PRIM_TYPE_TRIANGLES :
                                                PRIM_TYPE_INVALID));
                            assert(pg->inline_buffer_length ==
                                   (mode == 2 ? 2 : 0));
                            if (mode == 1) {
                                begin(PRIM_TYPE_TRIANGLES);
                                inline_position(0, 0);
                                inline_position(8, 0);
                            }
                            restores++;
                        }
                        inline_position(0, 8);
                        end();
                        array_current_check(expected);
                        for (unsigned y = 0; y < 8; y++)
                            for (unsigned x = 0; x < 8; x++) {
                                assert(color(x, y) ==
                                       (x + y < 7 ? 0xff00ff00 : 0xffff0000));
                                words++;
                            }
                        if (fd >= 0)
                            close(fd);
                        cases++;
                    }
    }
    assert(cases == 396 && restores == 264 && nonlast == 342 &&
           words == 25344 && formats == 63);
    groups++;
    printf(
        "Array Current restore: %u cases/%u closed-or-open Immediate restores/"
        "%u exact pixel words; ranges2/4/16 all final-range rotations, "
        "16 active attributes/six formats, highest-index Current and "
        "following Immediate PASS; no Xbox highest-vs-last proof\n",
        cases, restores, words);
}
#endif
