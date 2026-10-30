/* Isolated native Metal 4 byte blits against GL's CPU row algorithm.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "hw/xbox/nv2a/pgraph/metal/blit.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static NV2AMetalCommands *commands;
static NV2AMetalBlit *blit;
static unsigned checks, rejects;
static BOOL distinct_alias;
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Blit: %s\n", error.localizedDescription.UTF8String);
        abort();
    }
}
static void reference(uint8_t *source, uint8_t *dest,
                      const NV2AMetalBlitConfig *c)
{
    unsigned bpp = c->format == NV062_SET_COLOR_FORMAT_LE_Y8     ? 1 :
                   c->format == NV062_SET_COLOR_FORMAT_LE_R5G6B5 ? 2 :
                                                                   4;
    for (unsigned y = 0; y < c->rows + (c->tail_bytes != 0); y++) {
        unsigned bytes = y < c->rows ? c->row_bytes : c->tail_bytes;
        uint8_t *s = source + c->source_offset + y * c->source_pitch;
        uint8_t *d = dest + c->destination_offset + y * c->destination_pitch;
        if (c->operation == NV09F_SET_OPERATION_SRCCOPY)
            memmove(d, s, bytes);
        else
            for (unsigned x = 0; x < bytes / bpp; x++)
                for (unsigned ch = 0; ch < 3; ch++) {
                    unsigned beta = c->beta >> 16;
                    d[x * 4 + ch] = (s[x * 4 + ch] * beta +
                                     d[x * 4 + ch] * (0x7f80 - beta)) /
                                    0x7f80;
                }
    }
    if (c->format == NV062_SET_COLOR_FORMAT_LE_X8R8G8B8 ||
        c->format == NV062_SET_COLOR_FORMAT_LE_X8R8G8B8_Z8R8G8B8) {
        uint8_t alpha =
            c->format == NV062_SET_COLOR_FORMAT_LE_X8R8G8B8 ? 255 : 0;
        for (unsigned y = 0; y < c->rows + (c->tail_bytes != 0); y++)
            for (unsigned x = 0;
                 x < (y < c->rows ? c->row_bytes : c->tail_bytes) / 4; x++)
                dest[c->destination_offset + y * c->destination_pitch + x * 4 +
                     3] = alpha;
    }
}
static void run(NV2AMetalBlitConfig c, BOOL alias)
{
    const NSUInteger size = 131072;
    void *memory = NULL;
    id<MTLBuffer> source, dest;
    if (alias && distinct_alias) {
        assert(!posix_memalign(&memory, getpagesize(), size));
        source = [commands.device
            newBufferWithBytesNoCopy:memory
                              length:size
                             options:MTLResourceStorageModeShared
                         deallocator:nil];
        dest = [commands.device
            newBufferWithBytesNoCopy:memory
                              length:size
                             options:MTLResourceStorageModeShared
                         deallocator:nil];
    } else {
        source =
            [commands.device newBufferWithLength:size
                                         options:MTLResourceStorageModeShared];
        dest = alias ? source :
                       [commands.device
                           newBufferWithLength:size
                                       options:MTLResourceStorageModeShared];
    }
    assert(source && dest);
    uint8_t *expected_s = malloc(size),
            *expected_d = alias ? expected_s : malloc(size);
    assert(expected_s && expected_d);
    for (unsigned i = 0; i < size; i++) {
        ((uint8_t *)source.contents)[i] = expected_s[i] =
            (i * 47 + (i >> 8) * 19 + 37) & 255;
        if (!alias)
            ((uint8_t *)dest.contents)[i] = expected_d[i] =
                (i * 31 + (i >> 6) * 13 + 93) & 255;
    }
    reference(expected_s, expected_d, &c);
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    require([blit encodeSource:source
                   destination:dest
                        config:&c
                      commands:commands
                         error:&error],
            error);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    if (memcmp(source.contents, expected_s, size) ||
        memcmp(dest.contents, expected_d, size)) {
        for (unsigned i = 0; i < size; i++)
            if (((uint8_t *)dest.contents)[i] != expected_d[i]) {
                fprintf(stderr,
                        "Blit%u format%x op%u alias%d src%u dst%u pitches%u/%u "
                        "rows%u bytes%u tail%u beta%x byte%u: %u != %u\n",
                        checks, c.format, c.operation, alias, c.source_offset,
                        c.destination_offset, c.source_pitch,
                        c.destination_pitch, c.rows, c.row_bytes, c.tail_bytes,
                        c.beta, i, ((uint8_t *)dest.contents)[i],
                        expected_d[i]);
                break;
            }
        abort();
    }
    free(expected_s);
    if (!alias)
        free(expected_d);
    source = dest = nil;
    free(memory);
    checks++;
}
static void partial_views(void)
{
    NSUInteger page = getpagesize(), size = 3 * page;
    void *memory;
    assert(!posix_memalign(&memory, page, size));
    uint8_t *expected = malloc(size);
    assert(expected);
    for (NSUInteger i = 0; i < size; i++)
        ((uint8_t *)memory)[i] = expected[i] =
            (i * 23 + (i / page) * 31 + 9) & 255;
    id<MTLBuffer> source =
        [commands.device newBufferWithBytesNoCopy:memory
                                           length:2 * page
                                          options:MTLResourceStorageModeShared
                                      deallocator:nil];
    id<MTLBuffer> dest =
        [commands.device newBufferWithBytesNoCopy:(uint8_t *)memory + page
                                           length:2 * page
                                          options:MTLResourceStorageModeShared
                                      deallocator:nil];
    assert(source && dest);
    NV2AMetalBlitConfig c = { .format = NV062_SET_COLOR_FORMAT_LE_X8R8G8B8,
                              .operation = NV09F_SET_OPERATION_SRCCOPY,
                              .source_pitch = (unsigned)page,
                              .destination_pitch = (unsigned)page,
                              .row_bytes = (unsigned)page,
                              .rows = 2 };
    reference(expected, expected + page, &c);
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    require([blit encodeSource:source
                   destination:dest
                        config:&c
                      commands:commands
                         error:&error],
            error);
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
    assert(!memcmp(memory, expected, size));
    source = dest = nil;
    free(memory);
    free(expected);
    checks++;
}
int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        commands = [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        blit = [[NV2AMetalBlit alloc] initWithDevice:commands.device
                                               error:&error];
        require(blit != nil, error);
        unsigned formats[] = { NV062_SET_COLOR_FORMAT_LE_Y8,
                               NV062_SET_COLOR_FORMAT_LE_R5G6B5,
                               NV062_SET_COLOR_FORMAT_LE_A8R8G8B8,
                               NV062_SET_COLOR_FORMAT_LE_X8R8G8B8,
                               NV062_SET_COLOR_FORMAT_LE_X8R8G8B8_Z8R8G8B8,
                               NV062_SET_COLOR_FORMAT_LE_Y32 };
        for (unsigned f = 0; f < 6; f++) {
            unsigned bpp = f == 0 ? 1 : f == 1 ? 2 : 4;
            for (unsigned op = 2; op <= 3; op++)
                for (unsigned pattern = 0; pattern < 9; pattern++) {
                    NV2AMetalBlitConfig c = { .format = formats[f],
                                              .operation = op,
                                              .beta = 0x35800000,
                                              .source_offset = 256,
                                              .destination_offset = 8192,
                                              .source_pitch = 80,
                                              .destination_pitch = 96,
                                              .row_bytes = bpp * 9,
                                              .rows = 4,
                                              .tail_bytes = 7 * bpp - 1 };
                    BOOL alias = pattern != 0;
                    if (pattern == 1)
                        c.destination_offset = c.source_offset + bpp;
                    if (pattern == 2)
                        c.destination_offset = c.source_offset - bpp;
                    if (pattern == 3) {
                        c.source_pitch = c.destination_pitch = 80;
                        c.destination_offset = c.source_offset + 80;
                    }
                    if (pattern == 4) {
                        c.source_pitch = c.destination_pitch = 80;
                        c.destination_offset = c.source_offset - 80;
                    }
                    if (pattern == 5) {
                        c.destination_offset = c.source_offset;
                        c.source_pitch = c.destination_pitch;
                    }
                    if (pattern == 6) {
                        c.destination_offset = c.source_offset + 1;
                        c.destination_pitch = 40;
                    }
                    if (pattern == 7) {
                        c.rows = 0;
                        c.destination_offset = c.source_offset + 3;
                    }
                    if (pattern == 8) {
                        c.tail_bytes = 111;
                        c.destination_offset = c.source_offset + 4;
                    }
                    run(c, alias);
                }
        }
        // Every beta value the existing NV012 method can produce.
        for (unsigned beta = 0; beta < 256; beta++) {
            NV2AMetalBlitConfig c = { .format =
                                          NV062_SET_COLOR_FORMAT_LE_A8R8G8B8,
                                      .operation =
                                          NV09F_SET_OPERATION_BLEND_AND,
                                      .beta = beta << 23,
                                      .source_offset = 8,
                                      .destination_offset = 16384,
                                      .source_pitch = 1024,
                                      .destination_pitch = 1024,
                                      .row_bytes = 1024,
                                      .rows = 1 };
            run(c, NO);
        }
        // Multiple cooperative chunks, vertical propagation, and changing row
        // directions.
        for (unsigned direction = 0; direction < 4; direction++) {
            NV2AMetalBlitConfig c = { .format =
                                          NV062_SET_COLOR_FORMAT_LE_X8R8G8B8,
                                      .operation = NV09F_SET_OPERATION_SRCCOPY,
                                      .source_offset = 8192,
                                      .destination_offset = 8196,
                                      .source_pitch = 8192,
                                      .destination_pitch = 8192,
                                      .row_bytes = 8192,
                                      .rows = 8 };
            if (direction == 1)
                c.destination_offset = c.source_offset - 4;
            if (direction == 2)
                c.destination_offset = c.source_offset + 8192;
            if (direction == 3) {
                c.destination_offset += 1000;
                c.source_pitch = 10000;
            }
            run(c, YES);
        }
        distinct_alias = YES;
        for (unsigned op = 2; op <= 3; op++) {
            NV2AMetalBlitConfig alias_config = {
                .format = NV062_SET_COLOR_FORMAT_LE_X8R8G8B8,
                .operation = op,
                .beta = 0x35800000,
                .source_offset = 256,
                .destination_offset = 260,
                .source_pitch = 128,
                .destination_pitch = 128,
                .row_bytes = 128,
                .rows = 8
            };
            run(alias_config, YES);
        }
        distinct_alias = NO;
        partial_views();
        NV2AMetalBlitConfig c = { .format = NV062_SET_COLOR_FORMAT_LE_A8R8G8B8,
                                  .operation = NV09F_SET_OPERATION_SRCCOPY,
                                  .source_pitch = 64,
                                  .destination_pitch = 64,
                                  .row_bytes = 32,
                                  .rows = 1 };
        NV2AMetalBlitLayout layout;
        assert(!nv2a_metal_blit_layout(NULL, &layout, &error));
        rejects++;
        for (unsigned test = 0; test < 5; test++) {
            NV2AMetalBlitConfig bad = c;
            if (test == 0)
                bad.format = 3;
            if (test == 1)
                bad.operation = 1;
            if (test == 2) {
                bad.operation = 2;
                bad.beta = 0x7f810000;
            }
            if (test == 3)
                bad.source_pitch = 31;
            if (test == 4) {
                bad.source_offset = UINT32_MAX - 1;
            }
            assert(!nv2a_metal_blit_layout(&bad, &layout, &error));
            rejects++;
        }
        id<MTLBuffer> small =
            [commands.device newBufferWithLength:31
                                         options:MTLResourceStorageModeShared];
        require([commands beginWithError:&error] != nil, error);
        assert(![blit encodeSource:small
                       destination:small
                            config:&c
                          commands:commands
                             error:&error]);
        rejects++;
        [commands cancel];
        assert(![blit encodeSource:small
                       destination:small
                            config:&c
                          commands:commands
                             error:&error]);
        rejects++;
        printf(
            "Metal 4 blit: %u exact full-buffer comparisons, %u rejects PASS\n",
            checks, rejects);
    }
    return 0;
}
