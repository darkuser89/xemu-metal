/* Isolated GPU VGA graphics vs independent byte/bit reference.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "hw/xbox/nv2a/pgraph/metal/vga.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "VGA: %s\n", error.localizedDescription.UTF8String);
        abort();
    }
}
static uint32_t reference(const uint8_t *data, NV2AMetalVGARow row,
                          NV2AMetalVGAUniforms u, unsigned px)
{
    if (u.mode == 1) {
        unsigned cell = px / u.character_width, dx = px % u.character_width,
                 a = row.address + cell * 4;
        unsigned ch = data[a], attribute = data[a + 1];
        unsigned bitmap =
            data[u.font_offset[(attribute >> 3) & 1] + ch * 128 + row.hpel * 4];
        bool ink = dx < 8 ? ((bitmap >> (7 - dx)) & 1) : false;
        if (u.character_width == 16)
            ink = (bitmap >> (7 - dx / 2)) & 1;
        if (u.character_width == 9 && dx == 8)
            ink = u.line_graphics && ch >= 0xb0 && ch <= 0xdf && (bitmap & 1);
        bool cursor = u.cursor_visible && a == u.cursor_address &&
                      row.hpel >= u.cursor_start && row.hpel <= u.cursor_end;
        return u.palette[cursor || ink ? attribute & 15 : attribute >> 4] |
               0xff000000;
    }
    if (u.mode == 255)
        return 0xff000000;
    unsigned x = px, address;
    uint32_t rgb;
    if (u.mode == 2 || u.mode == 4) {
        x = px / (u.duplicate ? 2 : 1) + row.hpel;
        address = ((row.address + x / 8 * 4) & 0x3ffff) & u.memory_mask & ~3u;
        unsigned index = 0;
        if (u.mode == 4) {
            for (unsigned p = 0; p < 4; p++)
                if (u.plane_mask & (1u << p))
                    index |= ((data[address + p] >> (7 - x % 8)) & 1) << p;
        }
        if (u.mode == 2) {
            unsigned p = x % 8 / 4, shift = 6 - 2 * (x % 4);
            unsigned a = u.plane_mask & (1u << p) ? data[address + p] : 0,
                     b = u.plane_mask & (1u << (p + 2)) ?
                             data[address + p + 2] :
                             0;
            index = ((a >> shift) & 3) | (((b >> shift) & 3) << 2);
        }
        return u.palette[index] | 0xff000000;
    }
    if (u.mode == 8 || u.mode == 0) {
        x = (u.mode == 0 ? px / 2 : px) + row.hpel;
        address = u.mode == 0 ?
                      (((row.address + x / 4 * 4) & 0x3ffff) + x % 4) :
                      (row.address + x);
        return u.palette[data[address & u.memory_mask]] | 0xff000000;
    }
    if (u.mode == 15 || u.mode == 16) {
        address = (row.address + px * 2) & u.memory_mask & ~1u;
        unsigned v = u.big_endian ? (data[address] << 8) | data[address + 1] :
                                    data[address] | data[address + 1] << 8;
        unsigned r = u.mode == 15 ? (v >> 7) & 248 : (v >> 8) & 248,
                 g = u.mode == 15 ? (v >> 2) & 248 : (v >> 3) & 252,
                 b = (v << 3) & 248;
        rgb = r | g << 8 | b << 16;
    } else {
        unsigned stride = u.mode == 24 ? 3 : 4;
        address = row.address + px * stride;
        unsigned r, g, b;
        if (u.big_endian) {
            unsigned skip = stride == 4 ? 1 : 0;
            r = data[(address + skip) & u.memory_mask];
            g = data[(address + skip + 1) & u.memory_mask];
            b = data[(address + skip + 2) & u.memory_mask];
        } else {
            b = data[address & u.memory_mask];
            g = data[(address + 1) & u.memory_mask];
            r = data[(address + 2) & u.memory_mask];
        }
        rgb = r | g << 8 | b << 16;
    }
    return rgb | 0xff000000;
}
int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        NV2AMetalVGA *vga = [[NV2AMetalVGA alloc] initWithDevice:commands.device
                                                           error:&error];
        require(vga != nil, error);
        id<MTLBuffer> data =
            [commands.device newBufferWithLength:524288
                                         options:MTLResourceStorageModeShared];
        assert(data);
        uint8_t *ram = data.contents;
        for (unsigned i = 0; i < data.length; i++)
            ram[i] = (i * 37 + (i >> 7) * 19 + 17) & 255;
        unsigned modes[] = { 0, 2, 4, 8, 15, 16, 24, 32, 255 }, images = 0,
                 pixels = 0, rejects = 0;
        for (unsigned m = 0; m < 9; m++)
            for (unsigned endian = 0; endian < 2; endian++)
                for (unsigned pan = 0; pan < 8; pan++) {
                    NV2AMetalVGAUniforms u = {
                        .width = 32,
                        .height = 5,
                        .mode = modes[m],
                        .memory_mask = pan & 1 ? 65535 : 524287,
                        .plane_mask = pan ? pan * 2 : 15,
                        .big_endian = endian,
                        .duplicate = endian && (modes[m] == 2 || modes[m] == 4)
                    };
                    NV2AMetalVGARow rows[5] = { { 0, pan },
                                                { 513, pan },
                                                { 65530, pan },
                                                { 262142, pan },
                                                { 524284, pan } };
                    for (unsigned i = 0; i < 256; i++)
                        u.palette[i] = ((i * 13) & 255) |
                                       ((i * 29) & 255) << 8 |
                                       ((i * 61) & 255) << 16 | 0xff000000;
                    require([commands beginWithError:&error] != nil, error);
                    id<MTLTexture> texture = [vga encodeData:data
                                                        rows:rows
                                                    uniforms:&u
                                                    commands:commands
                                                       error:&error];
                    require(texture != nil, error);
                    id<MTLBuffer> output = [commands.device
                        newBufferWithLength:256 * 5
                                    options:MTLResourceStorageModeShared];
                    assert(output);
                    require([commands addResource:output error:&error], error);
                    id<MTL4ComputeCommandEncoder> e =
                        [commands.commandBuffer computeCommandEncoder];
                    assert(e);
                    [e barrierAfterQueueStages:MTLStageAll
                                  beforeStages:MTLStageBlit
                             visibilityOptions:MTL4VisibilityOptionDevice];
                    [e copyFromTexture:texture
                                     sourceSlice:0
                                     sourceLevel:0
                                    sourceOrigin:MTLOriginMake(0, 0, 0)
                                      sourceSize:MTLSizeMake(32, 5, 1)
                                        toBuffer:output
                               destinationOffset:0
                          destinationBytesPerRow:256
                        destinationBytesPerImage:0
                                         options:MTLBlitOptionNone];
                    [e endEncoding];
                    require([commands submitWithError:&error], error);
                    require([commands waitUntilIdleWithError:&error], error);
                    for (unsigned y = 0; y < 5; y++)
                        for (unsigned x = 0; x < 32; x++) {
                            uint32_t actual;
                            memcpy(&actual,
                                   (uint8_t *)output.contents + y * 256 + x * 4,
                                   4);
                            uint32_t want = reference(ram, rows[y], u, x);
                            if (actual != want) {
                                fprintf(stderr,
                                        "VGA mode%u endian%u pan%u pixel%u,%u: "
                                        "%08x != %08x\n",
                                        u.mode, endian, pan, x, y, actual,
                                        want);
                                abort();
                            }
                            pixels++;
                        }
                    images++;
                }
        for (unsigned cw_index = 0; cw_index < 3; cw_index++)
            for (unsigned variant = 0; variant < 16; variant++) {
                unsigned cw = (unsigned[]){ 8, 9, 16 }[cw_index];
                NV2AMetalVGAUniforms u = { .width = 4 * cw,
                                           .height = 64,
                                           .mode = 1,
                                           .memory_mask = 524287,
                                           .text_columns = 4,
                                           .character_width = cw,
                                           .character_height = 32,
                                           .font_offset = { 2, 32770 },
                                           .cursor_visible = variant & 1,
                                           .cursor_start = variant % 32,
                                           .cursor_end = variant % 32 + 3,
                                           .cursor_address = 400004,
                                           .line_graphics = !!(variant & 2) };
                for (unsigned i = 0; i < 16; i++)
                    u.palette[i] = ((i * 13) & 255) | ((i * 29) & 255) << 8 |
                                   ((i * 61) & 255) << 16 | 0xff000000;
                NV2AMetalVGARow rows[64];
                for (unsigned y = 0; y < 64; y++)
                    rows[y] =
                        (NV2AMetalVGARow){ y < 32 ? 400000 : 400064, y % 32 };
                for (unsigned row = 0; row < 2; row++)
                    for (unsigned col = 0; col < 4; col++) {
                        ram[400000 + row * 64 + col * 4] =
                            (uint8_t[]){ 0xaf, 0xb0, 0xdf, 0xe0 }[col] +
                            (variant & 4 ? 3 : 0);
                        ram[400001 + row * 64 + col * 4] =
                            (row ? 0x70 : 0x20) | (col + variant) % 16;
                    }
                require([commands beginWithError:&error] != nil, error);
                id<MTLTexture> texture = [vga encodeData:data
                                                    rows:rows
                                                uniforms:&u
                                                commands:commands
                                                   error:&error];
                require(texture != nil, error);
                id<MTLBuffer> output = [commands.device
                    newBufferWithLength:256 * 64
                                options:MTLResourceStorageModeShared];
                assert(output);
                require([commands addResource:output error:&error], error);
                id<MTL4ComputeCommandEncoder> e =
                    [commands.commandBuffer computeCommandEncoder];
                assert(e);
                [e barrierAfterQueueStages:MTLStageAll
                              beforeStages:MTLStageBlit
                         visibilityOptions:MTL4VisibilityOptionDevice];
                [e copyFromTexture:texture
                                 sourceSlice:0
                                 sourceLevel:0
                                sourceOrigin:MTLOriginMake(0, 0, 0)
                                  sourceSize:MTLSizeMake(u.width, 64, 1)
                                    toBuffer:output
                           destinationOffset:0
                      destinationBytesPerRow:256
                    destinationBytesPerImage:0
                                     options:MTLBlitOptionNone];
                [e endEncoding];
                require([commands submitWithError:&error], error);
                require([commands waitUntilIdleWithError:&error], error);
                for (unsigned y = 0; y < 64; y++)
                    for (unsigned x = 0; x < u.width; x++) {
                        uint32_t actual;
                        memcpy(&actual,
                               (uint8_t *)output.contents + y * 256 + x * 4, 4);
                        assert(actual == reference(ram, rows[y], u, x));
                        pixels++;
                    }
                images++;
            }
        NV2AMetalVGAUniforms u = {
            .width = 32, .height = 1, .mode = 32, .memory_mask = 524287
        };
        NV2AMetalVGARow row = { 0, 0 };
        require([commands beginWithError:&error] != nil, error);
        for (unsigned t = 0; t < 4; t++) {
            NV2AMetalVGAUniforms bad = u;
            if (t == 0)
                bad.mode = 3;
            if (t == 1)
                bad.memory_mask = 524288;
            if (t == 2)
                bad.memory_mask = 1048575;
            if (t == 3)
                bad.width = 0;
            assert(![vga encodeData:data
                               rows:&row
                           uniforms:&bad
                           commands:commands
                              error:&error]);
            rejects++;
        }
        u = (NV2AMetalVGAUniforms){ .width = 8,
                                    .height = 1,
                                    .mode = 1,
                                    .memory_mask = 524287,
                                    .text_columns = 1,
                                    .character_width = 8,
                                    .character_height = 1,
                                    .font_offset = { 2, 2 } };
        row = (NV2AMetalVGARow){ 0, 0 };
        for (unsigned t = 0; t < 3; t++) {
            NV2AMetalVGAUniforms bad = u;
            NV2AMetalVGARow badrow = row;
            if (t == 0)
                bad.font_offset[1] = 524288;
            if (t == 1)
                badrow.address = 524287;
            if (t == 2)
                bad.character_width = 10;
            assert(![vga encodeData:data
                               rows:&badrow
                           uniforms:&bad
                           commands:commands
                              error:&error]);
            rejects++;
        }
        [commands cancel];
        printf("Metal4 VGA graphics: %u exact images, %u pixels, %u rejects "
               "PASS\n",
               images, pixels, rejects);
    }
    return 0;
}
