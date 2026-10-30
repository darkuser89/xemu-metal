/* Offscreen Metal 4 VRAM coherence tests
 * SPDX-License-Identifier: LGPL-2.0-or-later */

#import "hw/xbox/nv2a/pgraph/metal/surface-cache.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned checks;
static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Surface cache: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}

static NV2AMetalSurfaceConfig config(unsigned format, BOOL color,
                                     unsigned bytes, unsigned scale,
                                     BOOL swizzle)
{
    return (NV2AMetalSurfaceConfig){ .format = format,
                                     .width = 8,
                                     .height = 4,
                                     .pitch = 12 * bytes,
                                     .scale = scale,
                                     .color = color,
                                     .swizzle = swizzle };
}

static void clear_surface(NV2AMetalSurfaceCache *cache,
                          NV2AMetalCachedSurface *surface, MTLClearColor color,
                          double depth, unsigned stencil)
{
    NSError *error = nil;
    id<MTLTexture> texture = surface.transfer.texture;
    require([cache.commands addResource:texture error:&error], error);
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    if (surface.transfer.config.color) {
        p.colorAttachments[0].texture = texture;
        p.colorAttachments[0].loadAction = MTLLoadActionClear;
        p.colorAttachments[0].storeAction = MTLStoreActionStore;
        p.colorAttachments[0].clearColor = color;
    } else {
        p.depthAttachment.texture = texture;
        p.depthAttachment.loadAction = MTLLoadActionClear;
        p.depthAttachment.storeAction = MTLStoreActionStore;
        p.depthAttachment.clearDepth = depth;
        if (texture.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
            p.stencilAttachment.texture = texture;
            p.stencilAttachment.loadAction = MTLLoadActionClear;
            p.stencilAttachment.storeAction = MTLStoreActionStore;
            p.stencilAttachment.clearStencil = stencil;
        }
    }
    id<MTL4RenderCommandEncoder> e =
        [cache.commands.commandBuffer renderCommandEncoderWithDescriptor:p];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    require([cache markWritten:surface error:&error], error);
}

static unsigned bytes_for(NV2AMetalSurfaceConfig c)
{
    NV2AMetalSurfaceLayout layout;
    assert(nv2a_metal_surface_layout(&c, &layout, NULL));
    return layout.bytes_per_pixel;
}

static void check_region(id<MTLBuffer> vram, NSUInteger address,
                         NV2AMetalSurfaceConfig c, unsigned word,
                         unsigned char padding)
{
    unsigned bytes = bytes_for(c);
    const unsigned char *raw = vram.contents;
    for (unsigned y = 0; y < c.height; y++) {
        for (unsigned x = 0; x < c.pitch; x++) {
            NSUInteger at = address + y * c.pitch + x;
            BOOL pixel = c.swizzle ?
                             y * c.pitch + x < c.width * c.height * bytes :
                             x < c.width * bytes;
            unsigned char expected =
                pixel ? word >> (8 * (x % bytes)) : padding;
            if (raw[at] != expected) {
                fprintf(stderr, "VRAM at %zu got %u expected %u\n", (size_t)at,
                        raw[at], expected);
                abort();
            }
        }
    }
    checks++;
}

static void check_clear_preserves(id<MTLBuffer> vram, NSUInteger address,
                                  NV2AMetalSurfaceConfig c, unsigned word,
                                  NSData *before)
{
    NSMutableData *expected = [before mutableCopy];
    unsigned char *raw = expected.mutableBytes;
    unsigned bytes = bytes_for(c);
    for (unsigned y = 0; y < c.height; y++) {
        for (unsigned x = 0; x < c.width; x++) {
            for (unsigned b = 0; b < bytes; b++) {
                raw[address + y * c.pitch + x * bytes + b] = word >> (8 * b);
            }
        }
    }
    assert(!memcmp(vram.contents, expected.bytes, vram.length));
    checks++;
}

static id<MTLBuffer> gpu_pixels(NV2AMetalSurfaceCache *cache,
                                NV2AMetalCachedSurface *surface)
{
    NSError *error = nil;
    id<MTLBuffer> result = [cache.commands.device
        newBufferWithLength:surface.transfer.sourceLength
                    options:MTLResourceStorageModeShared];
    assert(result);
    memset(result.contents, 0xcd, result.length);
    require([surface.transfer encodeDownloadToBuffer:result
                                              offset:0
                                             swizzle:YES
                                                flip:NO
                                           downscale:YES
                                            commands:cache.commands
                                               error:&error],
            error);
    require([cache submitWithError:&error], error);
    require([cache waitUntilIdleWithError:&error], error);
    return result;
}

static void coherence_tests(NV2AMetalCommands *commands, id<MTLBuffer> vram)
{
    NSError *error = nil;
    __block unsigned notifications = 0;
    NV2AMetalSurfaceCache *cache = [[NV2AMetalSurfaceCache alloc]
        initWithCommands:commands
                    vram:vram
            didWriteVRAM:^(NSUInteger address, NSUInteger length) {
              assert(!commands.commandBuffer);
              assert(address == 64 && length == 192);
              const unsigned char *raw = vram.contents;
              assert(raw[64] == (notifications == 1 ? 0 : 255));
              notifications++;
            }
                   error:&error];
    require(cache != nil, error);
    memset(vram.contents, 0x91, vram.length);
    NV2AMetalSurfaceConfig c =
        config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 2, NO);
    NV2AMetalCachedSurface *s = [cache prepareSurfaceAtAddress:64
                                                        config:&c
                                                         frame:1
                                                         error:&error];
    require(s != nil, error);
    assert(s.valid && !s.needsUpload && !s.dirty && cache.count == 1);
    assert(s.reservationLength == 192 && s.transfer.sourceLength == 176);
    uint64_t captured_generation = s.generation;
    assert([cache surfaceContainingAddress:255] == s);
    assert(![cache surfaceContainingAddress:256]);
    clear_surface(cache, s, MTLClearColorMake(1, 0, 1, 1), 0, 0);
    assert(s.dirty && s.generation > captured_generation);
    captured_generation = s.generation;
    assert(((unsigned char *)vram.contents)[64] == 0x91 && !notifications);
    require([cache submitWithError:&error], error);
    assert(s.dirty && !s.needsUpload && !notifications);
    require([cache prepareCPUAccessAtAddress:65
                                      length:1
                                       write:YES
                                       error:&error],
            error);
    assert(!s.dirty && s.needsUpload && notifications == 1);
    assert(s.generation > captured_generation);
    captured_generation = s.generation;
    check_region(vram, 64, c, 0xffff00ff, 0x91);
    ((unsigned char *)vram.contents)[65] = 0x55;
    NV2AMetalCachedSurface *same = [cache prepareSurfaceAtAddress:64
                                                           config:&c
                                                            frame:2
                                                            error:&error];
    assert(same == s && !s.needsUpload && s.generation == captured_generation);
    id<MTLBuffer> result = gpu_pixels(cache, s);
    const unsigned char *raw = result.contents;
    assert(raw[0] == 255 && raw[1] == 0x55 && raw[2] == 255 && raw[3] == 255);
    assert(raw[4] == 255 && raw[5] == 0 && raw[6] == 255 && raw[7] == 255);
    checks++;
    require([cache prepareSurfaceAtAddress:64 config:&c frame:2
                                     error:&error] != nil,
            error);
    clear_surface(cache, s, MTLClearColorMake(1, 0, 0, 1), 0, 0);
    require([cache prepareCPUAccessAtAddress:255
                                      length:1
                                       write:NO
                                       error:&error],
            error);
    assert(notifications == 2 && !s.dirty && !s.needsUpload);
    check_region(vram, 64, c, 0xffff0000, 0x91);
    require([cache prepareSurfaceAtAddress:64 config:&c frame:3
                                     error:&error] != nil,
            error);
    clear_surface(cache, s, MTLClearColorMake(1, 0, 1, 1), 0, 0);
    require([cache flushWithError:&error], error);
    assert(!s.valid && cache.count == 0 && notifications == 3);
    check_region(vram, 64, c, 0xffff00ff, 0x91);
}

static void cancel_tests(NV2AMetalCommands *commands, id<MTLBuffer> vram)
{
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:vram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    memset(vram.contents, 0x17, vram.length);
    NV2AMetalSurfaceConfig c =
        config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
    NV2AMetalCachedSurface *s = [cache prepareSurfaceAtAddress:0
                                                        config:&c
                                                         frame:0
                                                         error:&error];
    require(s != nil, error);
    uint64_t original_generation = s.generation;
    clear_surface(cache, s, MTLClearColorMake(0, 1, 0, 1), 0, 0);
    uint64_t cancelled_generation = s.generation;
    assert(s.dirty && !s.needsUpload &&
           cancelled_generation > original_generation);
    [cache cancel];
    assert(!s.dirty && s.needsUpload && !commands.commandBuffer);
    assert(s.generation == original_generation);
    s = [cache prepareSurfaceAtAddress:0 config:&c frame:1 error:&error];
    require(s != nil, error);
    id<MTLBuffer> result = gpu_pixels(cache, s);
    const unsigned char *raw = result.contents;
    for (unsigned y = 0; y < 4; y++) {
        for (unsigned b = 0; b < 32; b++) {
            assert(raw[y * 48 + b] == 0x17);
        }
    }
    require([cache prepareSurfaceAtAddress:0 config:&c frame:1
                                     error:&error] != nil,
            error);
    clear_surface(cache, s, MTLClearColorMake(0, 1, 0, 1), 0, 0);
    assert(s.generation > cancelled_generation);
    require([cache submitWithError:&error], error);
    uint64_t committed_generation = s.generation;
    require([cache prepareSurfaceAtAddress:0 config:&c frame:1
                                     error:&error] != nil,
            error);
    clear_surface(cache, s, MTLClearColorMake(1, 0, 0, 1), 0, 0);
    [cache cancel];
    assert(s.dirty && !s.needsUpload && s.generation == committed_generation);
    require([cache flushWithError:&error], error);
    check_region(vram, 0, c, 0xff00ff00, 0x17);
    checks++;
}

static void overlap_tests(NV2AMetalCommands *commands, id<MTLBuffer> vram)
{
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:vram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    memset(vram.contents, 0xa7, vram.length);
    NV2AMetalSurfaceConfig c =
        config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
    NV2AMetalCachedSurface *s = [cache prepareSurfaceAtAddress:64
                                                        config:&c
                                                         frame:10
                                                         error:&error];
    require(s != nil, error);
    clear_surface(cache, s, MTLClearColorMake(1, 0, 1, 1), 0, 0);
    NV2AMetalCachedSurface *overlap = [cache prepareSurfaceAtAddress:68
                                                              config:&c
                                                               frame:10
                                                               error:&error];
    require(overlap != nil, error);
    assert(!s.valid && overlap.valid && cache.count == 1);
    check_region(vram, 64, c, 0xffff00ff, 0xa7);
    id<MTLBuffer> result = gpu_pixels(cache, overlap);
    assert(!memcmp(result.contents, (unsigned char *)vram.contents + 68, 32));
    require([cache prepareSurfaceAtAddress:68
                                    config:&c
                                     frame:10
                                     error:&error] != nil,
            error);
    NSData *before = [NSData dataWithBytes:vram.contents length:vram.length];
    clear_surface(cache, overlap, MTLClearColorMake(0, 0, 1, 1), 0, 0);
    NV2AMetalSurfaceConfig narrow = c;
    narrow.width = 4;
    narrow.height = 2;
    NV2AMetalCachedSurface *larger = [cache prepareSurfaceAtAddress:68
                                                             config:&narrow
                                                              frame:11
                                                              error:&error];
    assert(larger == overlap && larger.transfer.config.width == 8 &&
           larger.frame == 11);
    NV2AMetalSurfaceConfig alias = c;
    alias.format = NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8;
    NV2AMetalCachedSurface *reinterpreted =
        [cache prepareSurfaceAtAddress:68 config:&alias frame:11 error:&error];
    require(reinterpreted != nil, error);
    assert(reinterpreted != overlap && !overlap.valid &&
           reinterpreted.transfer.config.format == alias.format);
    overlap = reinterpreted;
    NV2AMetalCachedSurface *adjacent = [cache prepareSurfaceAtAddress:260
                                                               config:&c
                                                                frame:11
                                                                error:&error];
    require(adjacent != nil, error);
    assert(overlap.valid && cache.count == 2);
    require([cache invalidateAddress:260 length:0 error:&error], error);
    assert(adjacent.valid && cache.count == 2);
    require([cache invalidateAddress:259 length:1 error:&error], error);
    assert(!overlap.valid && adjacent.valid && cache.count == 1);
    check_clear_preserves(vram, 68, c, 0xff0000ff, before);
    require([cache flushWithError:&error], error);
    checks++;
}

static void depth_encoding_alias(NV2AMetalCommands *commands,
                                 id<MTLBuffer> vram)
{
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:vram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    NV2AMetalSurfaceConfig c =
        config(NV097_SET_SURFACE_FORMAT_ZETA_Z24S8, NO, 4, 1, NO);
    NV2AMetalCachedSurface *fixed = [cache prepareSurfaceAtAddress:1024
                                                            config:&c
                                                             frame:1
                                                             error:&error];
    require(fixed != nil, error);
    clear_surface(cache, fixed, MTLClearColorMake(0, 0, 0, 0), .5, 0x5a);
    c.floating_depth = YES;
    NV2AMetalCachedSurface *floating = [cache prepareSurfaceAtAddress:1024
                                                               config:&c
                                                                frame:2
                                                                error:&error];
    require(floating != nil, error);
    assert(floating != fixed && !fixed.valid &&
           floating.transfer.config.floating_depth);
    assert(floating.transfer.texture.pixelFormat ==
           fixed.transfer.texture.pixelFormat);
    require([cache flushWithError:&error], error);
    checks++;
}
static void replacement_tests(NV2AMetalCommands *commands, id<MTLBuffer> vram)
{
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:vram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    NV2AMetalSurfaceConfig c =
        config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, YES);
    memset(vram.contents, 0x35, vram.length);
    NV2AMetalCachedSurface *s = [cache prepareSurfaceAtAddress:512
                                                        config:&c
                                                         frame:0
                                                         error:&error];
    require(s != nil, error);
    clear_surface(cache, s, MTLClearColorMake(1, 0, 0, 1), 0, 0);
    NV2AMetalSurfaceConfig linear = c;
    linear.swizzle = NO;
    NV2AMetalCachedSurface *changed = [cache prepareSurfaceAtAddress:512
                                                              config:&linear
                                                               frame:0
                                                               error:&error];
    require(changed != nil, error);
    assert(changed != s && !s.valid);
    check_region(vram, 512, c, 0xffff0000, 0x35);
    NSData *before = [NSData dataWithBytes:vram.contents length:vram.length];
    clear_surface(cache, changed, MTLClearColorMake(0, 1, 0, 1), 0, 0);
    linear.scale = 3;
    NV2AMetalCachedSurface *scaled = [cache prepareSurfaceAtAddress:512
                                                             config:&linear
                                                              frame:1
                                                              error:&error];
    require(scaled != nil, error);
    assert(!changed.valid && scaled.transfer.texture.width == 24);
    check_clear_preserves(vram, 512, changed.transfer.config, 0xff00ff00,
                          before);
    NV2AMetalSurfaceConfig depth =
        config(NV097_SET_SURFACE_FORMAT_ZETA_Z16, NO, 2, 1, NO);
    NV2AMetalCachedSurface *z = [cache prepareSurfaceAtAddress:512
                                                        config:&depth
                                                         frame:1
                                                         error:&error];
    require(z != nil, error);
    assert(!scaled.valid &&
           z.transfer.texture.pixelFormat == MTLPixelFormatDepth16Unorm);
    before = [NSData dataWithBytes:vram.contents length:vram.length];
    clear_surface(cache, z, MTLClearColorMake(0, 0, 0, 0), 1, 0);
    require([cache flushWithError:&error], error);
    check_clear_preserves(vram, 512, depth, 0xffff, before);
    checks++;
}

static void eviction_and_restore_tests(NV2AMetalCommands *commands,
                                       id<MTLBuffer> vram)
{
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:vram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    memset(vram.contents, 0x65, vram.length);
    NV2AMetalSurfaceConfig c =
        config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
    NV2AMetalCachedSurface *old = [cache prepareSurfaceAtAddress:0
                                                          config:&c
                                                           frame:10
                                                           error:&error];
    require(old != nil, error);
    clear_surface(cache, old, MTLClearColorMake(0, 0, 1, 1), 0, 0);
    require([cache evictBeforeFrame:9 error:&error], error);
    require([cache evictBeforeFrame:14 error:&error], error);
    assert(old.valid && old.dirty);
    require([cache evictBeforeFrame:15 error:&error], error);
    assert(!old.valid && !cache.count);
    check_region(vram, 0, c, 0xff0000ff, 0x65);
    NV2AMetalCachedSurface *last = [cache prepareSurfaceAtAddress:0
                                                           config:&c
                                                            frame:UINT64_MAX
                                                            error:&error];
    require(last != nil, error);
    require([cache evictBeforeFrame:0 error:&error], error);
    assert(last.valid);
    clear_surface(cache, last, MTLClearColorMake(1, 0, 1, 1), 0, 0);
    require([cache flushWithError:&error], error);
    NSMutableData *snapshot = [NSMutableData dataWithBytes:vram.contents
                                                    length:vram.length];
    memset(vram.contents, 0xb3, vram.length);
    NV2AMetalCachedSurface *new = [ cache prepareSurfaceAtAddress
                                    : 0 config : &c frame : 0 error : &error ];
    require(new != nil, error);
    id<MTLBuffer> pixels = gpu_pixels(cache, new);
    const unsigned char *bytes = pixels.contents;
    assert(bytes[0] == 0xb3 && bytes[31] == 0xb3);
    require([cache flushWithError:&error], error);
    memcpy(vram.contents, snapshot.bytes, vram.length);
    new = [ cache prepareSurfaceAtAddress : 0 config : &c frame
            : 0 error : &error ];
    require(new != nil, error);
    pixels = gpu_pixels(cache, new);
    bytes = pixels.contents;
    assert(bytes[0] == 255 && bytes[1] == 0 && bytes[2] == 255 &&
           bytes[3] == 255);
    require([cache flushWithError:&error], error);
    checks++;
}

static void format_tests(NV2AMetalCommands *commands, id<MTLBuffer> vram)
{
    NSError *error = nil;
    const unsigned formats[] = {
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8,
        NV097_SET_SURFACE_FORMAT_ZETA_Z16,
        NV097_SET_SURFACE_FORMAT_ZETA_Z24S8,
        NV097_SET_SURFACE_FORMAT_ZETA_Z16,
        NV097_SET_SURFACE_FORMAT_ZETA_Z24S8
    };
    const unsigned bytes[] = { 2, 2, 1, 2, 2, 4, 2, 4 };
    const unsigned words[] = { 0xfc1f, 0xf81f,     255,   255,
                               65535,  0xffffff5a, 65535, 0xffffff5a };
    for (unsigned i = 0; i < 8; i++) {
        @autoreleasepool {
            NV2AMetalSurfaceCache *cache =
                [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                           vram:vram
                                                   didWriteVRAM:nil
                                                          error:&error];
            require(cache != nil, error);
            memset(vram.contents, 0xe7, vram.length);
            NV2AMetalSurfaceConfig c =
                config(formats[i], i < 4, bytes[i], 2, YES);
            c.floating_depth = i >= 6;
            NV2AMetalCachedSurface *s = [cache prepareSurfaceAtAddress:1024
                                                                config:&c
                                                                 frame:0
                                                                 error:&error];
            require(s != nil, error);
            clear_surface(cache, s, MTLClearColorMake(1, 0, 1, 1), 1, 0x5a);
            require([cache prepareCPUAccessAtAddress:1024
                                              length:s.reservationLength
                                               write:NO
                                               error:&error],
                    error);
            check_region(vram, 1024, c, words[i], 0xe7);
            require([cache flushWithError:&error], error);
        }
    }
}

static void rejection_tests(NV2AMetalCommands *commands, id<MTLBuffer> vram)
{
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:vram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    NV2AMetalSurfaceConfig c =
        config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
    assert(![cache prepareSurfaceAtAddress:vram.length - 176
                                    config:&c
                                     frame:0
                                     error:&error]);
    assert(![cache prepareSurfaceAtAddress:NSUIntegerMax
                                    config:&c
                                     frame:0
                                     error:&error]);
    assert(![cache prepareSurfaceAtAddress:0 config:NULL frame:0 error:&error]);
    assert(![cache prepareCPUAccessAtAddress:0
                                      length:NSUIntegerMax
                                       write:YES
                                       error:&error]);
    assert(![cache invalidateAddress:NSUIntegerMax length:0 error:&error]);
    assert(!cache.count && !commands.commandBuffer);
    NV2AMetalCachedSurface *s = [cache prepareSurfaceAtAddress:0
                                                        config:&c
                                                         frame:0
                                                         error:&error];
    require(s != nil, error);
    assert(![cache waitUntilIdleWithError:&error]);
    assert(![[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                       vram:vram
                                               didWriteVRAM:nil
                                                      error:&error]);
    [cache cancel];
    assert(![cache markWritten:s error:&error]);
    require([cache invalidateAddress:0 length:1 error:&error], error);
    assert(!s.valid);
    NV2AMetalCachedSurface *next = [cache prepareSurfaceAtAddress:0
                                                           config:&c
                                                            frame:0
                                                            error:&error];
    require(next != nil, error);
    assert(![cache markWritten:s error:&error]);
    require([cache prepareCPUAccessAtAddress:vram.length
                                      length:0
                                       write:YES
                                       error:&error],
            error);
    assert(commands.commandBuffer);
    [cache cancel];
    id<MTLBuffer> private =
        [commands.device newBufferWithLength:256
                                     options:MTLResourceStorageModePrivate];
    assert(![[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                       vram:private
                                               didWriteVRAM:nil
                                                      error:&error]);
    require([commands beginWithError:&error] != nil, error);
    assert(![cache submitWithError:&error]);
    [commands cancel];
    require([cache flushWithError:&error], error);
    NV2AMetalCachedSurface *first = [cache prepareSurfaceAtAddress:0
                                                            config:&c
                                                             frame:0
                                                             error:&error];
    require(first != nil, error);
    require([cache submitWithError:&error], error);
    require([cache waitUntilIdleWithError:&error], error);
    require([cache prepareSurfaceAtAddress:256
                                    config:&c
                                     frame:0
                                     error:&error] != nil,
            error);
    assert(![cache markWritten:first error:&error]);
    [cache cancel];
    require([cache flushWithError:&error], error);
    checks++;
}

@interface CacheFailureCommands : NV2AMetalCommands
@property(nonatomic) BOOL failSubmit, failCompletion;
@property(nonatomic) BOOL omitCompletionError;
@property(nonatomic) id pollReceipt;
@end
@implementation CacheFailureCommands
- (NV2AMetalSubmission *)lastSubmitted
{
    return _pollReceipt ?: super.lastSubmitted;
}
- (BOOL)submitWithError:(NSError **)error
{
    if (_failSubmit) {
        _failSubmit = NO;
        if (error) {
            *error = [NSError errorWithDomain:@"surface-test"
                                         code:1
                                     userInfo:nil];
        }
        return NO;
    }
    return [super submitWithError:error];
}
- (BOOL)waitUntilIdleWithError:(NSError **)error
{
    if (![super waitUntilIdleWithError:error]) {
        return NO;
    }
    if (_failCompletion) {
        _failCompletion = NO;
        if (error) {
            *error = [NSError errorWithDomain:@"surface-test"
                                         code:2
                                     userInfo:nil];
        }
        return NO;
    }
    return YES;
}
- (BOOL)waitForSubmission:(NV2AMetalSubmission *)submission error:(NSError **)error
{
    if (![super waitForSubmission:submission error:error])
        return NO;
    if (!_failCompletion)
        return YES;
    _failCompletion = NO;
    if (error && !_omitCompletionError)
        *error = [NSError errorWithDomain:@"surface-test" code:2 userInfo:nil];
    return NO;
}
@end

static void failure_and_lifetime_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    CacheFailureCommands *commands =
        [[CacheFailureCommands alloc] initWithDevice:device error:&error];
    require(commands != nil, error);
    id<MTLBuffer> vram =
        [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    assert(vram);
    memset(vram.contents, 0x33, vram.length);
    __block unsigned published = 0;
    NV2AMetalSurfaceCache *cache = [[NV2AMetalSurfaceCache alloc]
        initWithCommands:commands
                    vram:vram
            didWriteVRAM:^(NSUInteger address, NSUInteger length) {
              assert(address == 64 && length == 192);
              assert(((unsigned char *)vram.contents)[64] == 255);
              published++;
            }
                   error:&error];
    require(cache != nil, error);
    NV2AMetalSurfaceConfig c =
        config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
    NV2AMetalCachedSurface *s = [cache prepareSurfaceAtAddress:64
                                                        config:&c
                                                         frame:0
                                                         error:&error];
    require(s != nil, error);
    clear_surface(cache, s, MTLClearColorMake(0, 0, 1, 1), 0, 0);
    commands.failSubmit = YES;
    assert(![cache submitWithError:&error]);
    assert(commands.commandBuffer && s.dirty && !s.needsUpload);
    [cache cancel];
    assert(!s.dirty && s.needsUpload);
    s = [cache prepareSurfaceAtAddress:64 config:&c frame:0 error:&error];
    require(s != nil, error);
    clear_surface(cache, s, MTLClearColorMake(0, 0, 1, 1), 0, 0);
    require([cache submitWithError:&error], error);
    commands.failSubmit = YES;
    assert(![cache prepareCPUAccessAtAddress:64
                                      length:1
                                       write:YES
                                       error:&error]);
    assert(!published && commands.commandBuffer);
    [cache cancel];
    assert(s.dirty && !s.needsUpload);
    require([cache prepareCPUAccessAtAddress:64 length:1 write:NO error:&error],
            error);
    assert(published == 1);
    check_region(vram, 64, c, 0xff0000ff, 0x33);
    require([cache prepareSurfaceAtAddress:64 config:&c frame:0
                                     error:&error] != nil,
            error);
    clear_surface(cache, s, MTLClearColorMake(1, 0, 1, 1), 0, 0);
    commands.failSubmit = YES;
    assert(![cache flushWithError:&error]);
    assert(s.valid && cache.count == 1 && published == 1);
    require([cache flushWithError:&error], error);
    assert(!s.valid && cache.count == 0 && published == 2);
    checks++;
    s = [cache prepareSurfaceAtAddress:64 config:&c frame:0 error:&error];
    require(s != nil, error);
    clear_surface(cache, s, MTLClearColorMake(0, 0, 1, 1), 0, 0);
    commands.failCompletion = YES;
    assert(![cache flushWithError:&error]);
    assert(error.code == 2 && s.valid && cache.count == 1 && published == 2);
    assert(![cache prepareSurfaceAtAddress:64 config:&c frame:0 error:&error]);
    assert(![cache prepareCPUAccessAtAddress:64
                                      length:1
                                       write:YES
                                       error:&error]);
    assert(![cache invalidateAddress:64 length:1 error:&error]);
    uint64_t version;
    assert(![cache sourceVersionAtAddress:64
                                   length:1
                                  version:&version
                                    error:&error]);
    assert(error.code == 2);
    assert(![cache prepareGPUReadAtAddress:64 length:1 error:&error]);
    assert(error.code == 2);
    assert(![cache evictBeforeFrame:6 error:&error]);
    assert(![cache flushWithError:&error]);
    checks++;
    require([commands waitUntilIdleWithError:&error], error);
    cache = nil;
    s = nil;
    @autoreleasepool {
        cache = [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                           vram:vram
                                                   didWriteVRAM:nil
                                                          error:&error];
        require(cache != nil, error);
        __weak NV2AMetalCachedSurface *weak_surface;
        __weak id<MTLTexture> weak_texture;
        @autoreleasepool {
            NV2AMetalCachedSurface *local =
                [cache prepareSurfaceAtAddress:64
                                        config:&c
                                         frame:0
                                         error:&error];
            require(local != nil, error);
            weak_surface = local;
            weak_texture = local.transfer.texture;
            clear_surface(cache, local, MTLClearColorMake(1, 0, 1, 1), 0, 0);
        }
        assert(weak_surface && weak_texture);
        require([cache flushWithError:&error], error);
        assert(!weak_surface && !weak_texture);
        checks++;
    }
}

static void idle_cpu_access_tests(NV2AMetalCommands *commands,
                                  id<MTLBuffer> vram)
{
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:vram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    BOOL completed = NO;
    uint64_t before, after;
    require([cache sourceVersionAtAddress:3072
                                   length:4
                                  version:&before
                                    error:&error],
            error);
    require([cache tryIdleCPUAccessAtAddress:3072
                                      length:4
                                       write:NO
                                   completed:&completed
                                       error:&error],
            error);
    assert(completed && !cache.recording && !commands.commandBuffer);
    require([cache sourceVersionAtAddress:3072
                                   length:4
                                  version:&after
                                    error:&error],
            error);
    assert(before == after);
    require([cache tryIdleCPUAccessAtAddress:3072
                                      length:4
                                       write:YES
                                   completed:&completed
                                       error:&error],
            error);
    assert(completed);
    require([cache sourceVersionAtAddress:3072
                                   length:4
                                  version:&after
                                    error:&error],
            error);
    assert(after > before);
    checks++;

    memset(vram.contents, 0x31, vram.length);
    NV2AMetalSurfaceConfig c = config(8, YES, 4, 1, NO);
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:64
                                                              config:&c
                                                               frame:1
                                                               error:&error];
    require(surface != nil, error);
    clear_surface(cache, surface, MTLClearColorMake(1, 0, 0, 1), 0, 0);
    require([cache tryIdleCPUAccessAtAddress:3072
                                      length:4
                                       write:YES
                                   completed:&completed
                                       error:&error],
            error);
    assert(completed && surface.dirty && cache.recording);
    require([cache submitWithError:&error], error);
    require([cache tryIdleCPUAccessAtAddress:3072
                                      length:4
                                       write:NO
                                   completed:&completed
                                       error:&error],
            error);
    assert(completed && surface.dirty);
    require([cache waitUntilIdleWithError:&error], error);
    require([cache tryIdleCPUAccessAtAddress:3072
                                      length:4
                                       write:NO
                                   completed:&completed
                                       error:&error],
            error);
    assert(completed && surface.dirty);
    require([cache tryIdleCPUAccessAtAddress:64
                                      length:4
                                       write:YES
                                   completed:&completed
                                       error:&error],
            error);
    assert(!completed && surface.dirty);
    checks++;

    require([cache prepareCPUAccessAtAddress:64 length:4 write:NO error:&error],
            error);
    assert(!surface.dirty && ((uint32_t *)vram.contents)[16] == 0xffff0000);
    require([cache tryIdleCPUAccessAtAddress:65
                                      length:1
                                       write:YES
                                   completed:&completed
                                       error:&error],
            error);
    assert(completed && surface.needsUpload);
    ((uint8_t *)vram.contents)[65] = 0x55;
    surface = [cache prepareSurfaceAtAddress:64 config:&c frame:2 error:&error];
    require(surface != nil, error);
    id<MTLBuffer> pixels = gpu_pixels(cache, surface);
    assert(((const uint32_t *)pixels.contents)[0] == 0xffff5500);
    require([cache flushWithError:&error], error);
    checks++;

    require([cache tryIdleCPUAccessAtAddress:vram.length
                                      length:0
                                       write:YES
                                   completed:&completed
                                       error:&error],
            error);
    assert(completed);
    assert(![cache tryIdleCPUAccessAtAddress:vram.length
                                      length:1
                                       write:NO
                                   completed:&completed
                                       error:&error]);
    assert(!completed && error);
    error = nil;
    assert(![cache tryIdleCPUAccessAtAddress:NSUIntegerMax
                                      length:2
                                       write:YES
                                   completed:&completed
                                       error:&error]);
    assert(!completed && error);
    checks++;
}

static void active_cpu_read_tests(NV2AMetalCommands *commands,
                                  id<MTLBuffer> vram)
{
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:vram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    memset(vram.contents, 0x31, vram.length);
    NV2AMetalSurfaceConfig c = config(8, YES, 4, 1, NO);
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:64
                                                              config:&c
                                                               frame:1
                                                               error:&error];
    require(surface != nil, error);
    clear_surface(cache, surface, MTLClearColorMake(1, 0, 0, 1), 0, 0);
    BOOL completed = NO;
    NV2AMetalSurfaceRecording *token = cache.recording;
    id<MTL4CommandBuffer> buffer = commands.commandBuffer;
    uint64_t before, after;
    require([cache sourceVersionAtAddress:3072
                                   length:4
                                  version:&before
                                    error:&error],
            error);
    require([cache tryIdleCPUAccessAtAddress:3072
                                      length:4
                                       write:NO
                                   completed:&completed
                                       error:&error],
            error);
    require([cache sourceVersionAtAddress:3072
                                   length:4
                                  version:&after
                                    error:&error],
            error);
    assert(completed && token == cache.recording &&
           buffer == commands.commandBuffer && before == after &&
           surface.dirty);
    require([cache tryIdleCPUAccessAtAddress:64
                                      length:1
                                       write:NO
                                   completed:&completed
                                       error:&error],
            error);
    assert(!completed);
    require([cache prepareGPUReadAtAddress:64
                                    length:surface.reservationLength
                                     error:&error],
            error);
    assert(!surface.dirty && token == cache.recording);
    const NSUInteger addresses[] = { 0,
                                     63,
                                     64,
                                     65,
                                     64 + surface.reservationLength - 1,
                                     64 + surface.reservationLength,
                                     3072,
                                     vram.length - 1 };
    for (unsigned phase = 0; phase < 3; phase++) {
        if (phase == 1)
            require([cache submitWithError:&error], error);
        if (phase == 2)
            require([cache waitUntilIdleWithError:&error], error);
        for (unsigned i = 0; i < sizeof(addresses) / sizeof(addresses[0]);
             i++) {
            NSUInteger address = addresses[i];
            require([cache tryIdleCPUAccessAtAddress:address
                                              length:1
                                               write:NO
                                           completed:&completed
                                               error:&error],
                    error);
            BOOL overlaps =
                address >= 64 && address < 64 + surface.reservationLength;
            assert(completed == (phase == 2 || !overlaps));
        }
        require([cache tryIdleCPUAccessAtAddress:3072
                                          length:4
                                           write:YES
                                       completed:&completed
                                           error:&error],
                error);
        assert(completed);
    }
    assert(((uint32_t *)vram.contents)[16] == 0xffff0000 &&
           ((uint32_t *)vram.contents)[3072 / 4] == 0x31313131);
    require([cache flushWithError:&error], error);
    checks++;
}

static id<MTLBuffer> encode_vram_copy(NV2AMetalSurfaceCache *cache,
                                      NSUInteger address, NSUInteger length)
{
    NSError *error = nil;
    require([cache prepareGPUReadAtAddress:address length:length error:&error],
            error);
    id<MTLBuffer> output = [cache.commands.device
        newBufferWithLength:length
                    options:MTLResourceStorageModeShared];
    assert(output);
    require([cache.commands addResource:output error:&error], error);
    id<MTL4ComputeCommandEncoder> encoder =
        [cache.commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromBuffer:cache.vram
               sourceOffset:address
                   toBuffer:output
          destinationOffset:0
                       size:length];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return output;
}

static void cpu_write_range_tests(NV2AMetalCommands *commands,
                                  id<MTLBuffer> vram)
{
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:vram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    memset(vram.contents, 0x31, vram.length);
    id<MTLBuffer> first = encode_vram_copy(cache, 128, 32);
    id<MTLBuffer> second = encode_vram_copy(cache, 256, 32);
    id<MTLBuffer> third = nil;
    const NSUInteger spans[][2] = {
        { 0, 1 },   { 127, 1 },  { 127, 2 },  { 128, 1 },  { 159, 1 },
        { 160, 1 }, { 160, 96 }, { 160, 97 }, { 255, 2 },  { 256, 32 },
        { 288, 1 }, { 511, 1 },  { 511, 2 },  { 512, 32 }, { 543, 1 },
        { 544, 1 }, { 3072, 4 }, { 4095, 1 }, { 4096, 0 }
    };
    unsigned tested = 0;
    for (unsigned phase = 0; phase < 4; phase++) {
        if (phase == 1)
            require([cache submitWithError:&error], error);
        if (phase == 2)
            third = encode_vram_copy(cache, 512, 32);
        if (phase == 3) {
            require([cache submitWithError:&error], error);
            require([cache waitUntilIdleWithError:&error], error);
        }
        NV2AMetalSurfaceRecording *token = cache.recording;
        id<MTL4CommandBuffer> recording = commands.commandBuffer;
        for (unsigned i = 0; i < sizeof(spans) / sizeof(spans[0]); i++) {
            NSUInteger address = spans[i][0], length = spans[i][1];
            BOOL blocked =
                length && phase != 3 &&
                ((address < 160 && 128 < address + length) ||
                 (address < 288 && 256 < address + length) ||
                 (phase == 2 && address < 544 && 512 < address + length));
            for (unsigned write = 0; write < 2; write++) {
                BOOL completed = NO;
                uint64_t before, after;
                require([cache sourceVersionAtAddress:address
                                               length:length
                                              version:&before
                                                error:&error],
                        error);
                require([cache tryIdleCPUAccessAtAddress:address
                                                  length:length
                                                   write:write
                                               completed:&completed
                                                   error:&error],
                        error);
                require([cache sourceVersionAtAddress:address
                                               length:length
                                              version:&after
                                                error:&error],
                        error);
                assert(completed == (!write || !blocked));
                assert(token == cache.recording &&
                       recording == commands.commandBuffer);
                if (!write || !length || blocked)
                    assert(before == after);
                else
                    assert(after > before);
                tested++;
            }
        }
        BOOL completed = NO;
        require([cache tryIdleCPUAccessAtAddress:3072
                                          length:4
                                           write:YES
                                       completed:&completed
                                           error:&error],
                error);
        assert(completed);
        memset((uint8_t *)vram.contents + 3072, 0x40 + phase, 4);
    }
    for (id<MTLBuffer> result in @[ first, second, third ])
        for (NSUInteger i = 0; i < result.length; i++)
            assert(((const uint8_t *)result.contents)[i] == 0x31);
    assert(((const uint8_t *)vram.contents)[3072] == 0x43);

    encode_vram_copy(cache, 1024, 16);
    NV2AMetalSurfaceRecording *submitted = cache.recording;
    require([cache submitWithError:&error], error);
    encode_vram_copy(cache, 2048, 16);
    NV2AMetalSurfaceRecording *cancelled = cache.recording;
    [cache cancel];
    assert(cancelled.cancelled && submitted.submitted && !submitted.completed);
    BOOL completed = NO;
    require([cache tryIdleCPUAccessAtAddress:1024
                                      length:1
                                       write:YES
                                   completed:&completed
                                       error:&error],
            error);
    assert(!completed);
    require([cache tryIdleCPUAccessAtAddress:2048
                                      length:1
                                       write:YES
                                   completed:&completed
                                       error:&error],
            error);
    assert(completed);
    require([cache waitUntilIdleWithError:&error], error);
    require([cache tryIdleCPUAccessAtAddress:1024
                                      length:1
                                       write:YES
                                   completed:&completed
                                       error:&error],
            error);
    assert(completed && submitted.completed);

    require([cache prepareGPUReadAtAddress:vram.length length:0 error:&error],
            error);
    require([cache tryIdleCPUAccessAtAddress:3072
                                      length:1
                                       write:YES
                                   completed:&completed
                                       error:&error],
            error);
    assert(completed);
    assert(![cache prepareGPUReadAtAddress:vram.length length:1 error:&error]);
    assert(error);
    error = nil;
    [cache cancel];
    require([cache flushWithError:&error], error);
    checks += tested + 5;
    printf(
        "CPU write ranges: %u boundary/state checks, three GPU copies PASS\n",
        tested + 5);
}

static void transfer_write_range_tests(NV2AMetalCommands *commands,
                                       id<MTLBuffer> vram)
{
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:vram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    memset(vram.contents, 0x31, vram.length);
    NV2AMetalSurfaceConfig c = config(8, YES, 4, 1, NO);
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:64
                                                              config:&c
                                                               frame:1
                                                               error:&error];
    require(surface != nil, error);
    BOOL completed = NO;
    require([cache submitWithError:&error], error);
    require([cache tryIdleCPUAccessAtAddress:65
                                      length:1
                                       write:YES
                                   completed:&completed
                                       error:&error],
            error);
    assert(!completed && !surface.dirty && !surface.needsUpload);
    require([cache tryIdleCPUAccessAtAddress:3072
                                      length:1
                                       write:YES
                                   completed:&completed
                                       error:&error],
            error);
    assert(completed);
    ((uint8_t *)vram.contents)[3072] = 0x55;
    require([cache waitUntilIdleWithError:&error], error);
    require([cache tryIdleCPUAccessAtAddress:65
                                      length:1
                                       write:YES
                                   completed:&completed
                                       error:&error],
            error);
    assert(completed && surface.needsUpload);
    ((uint8_t *)vram.contents)[65] = 0x77;
    surface = [cache prepareSurfaceAtAddress:64 config:&c frame:2 error:&error];
    require(surface != nil, error);
    id<MTLBuffer> pixels = gpu_pixels(cache, surface);
    assert(((const uint32_t *)pixels.contents)[0] == 0x31317731);

    // Start with the upload finished so only the one-byte GPU reader is
    // tracked.
    surface = [cache prepareSurfaceAtAddress:64 config:&c frame:3 error:&error];
    require(surface != nil, error);
    clear_surface(cache, surface, MTLClearColorMake(1, 0, 0, 1), 0, 0);
    require([cache prepareGPUReadAtAddress:64 length:1 error:&error], error);
    assert(!surface.dirty);
    const NSUInteger addresses[] = { 63,
                                     64,
                                     65,
                                     64 + surface.reservationLength - 1,
                                     64 + surface.reservationLength,
                                     3072 };
    unsigned tested = 0;
    for (unsigned phase = 0; phase < 3; phase++) {
        if (phase == 1)
            require([cache submitWithError:&error], error);
        if (phase == 2)
            require([cache waitUntilIdleWithError:&error], error);
        for (unsigned i = 0; i < sizeof(addresses) / sizeof(addresses[0]);
             i++) {
            NSUInteger address = addresses[i];
            BOOL overlaps =
                address >= 64 && address < 64 + surface.reservationLength;
            for (unsigned write = 0; write < 2; write++) {
                require([cache tryIdleCPUAccessAtAddress:address
                                                  length:1
                                                   write:write
                                               completed:&completed
                                                   error:&error],
                        error);
                assert(completed == (phase == 2 || !overlaps));
                tested++;
            }
        }
    }
    assert(((const uint32_t *)vram.contents)[16] == 0xffff0000 &&
           ((const uint8_t *)vram.contents)[3072] == 0x55);
    require([cache flushWithError:&error], error);
    checks += tested + 4;
    printf(
        "Transfer CPU write ranges: %u upload/download/padding checks PASS\n",
        tested + 4);
}

static void recording_write_tests(NV2AMetalCommands *commands,
                                  id<MTLBuffer> vram)
{
    NSError *error = nil;
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:vram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    memset(vram.contents, 0x31, vram.length);
    NV2AMetalSurfaceConfig c = config(8, YES, 4, 1, NO);
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:64
                                                              config:&c
                                                               frame:1
                                                               error:&error];
    require(surface != nil, error);
    require([cache submitWithError:&error], error);
    require([cache waitUntilIdleWithError:&error], error);
    surface = [cache prepareSurfaceAtAddress:64 config:&c frame:2 error:&error];
    require(surface != nil, error);
    require([cache markRTTSampling:surface error:&error], error);
    assert(!surface.dirty && !surface.needsUpload);
    BOOL completed = NO;
    require([cache tryIdleCPUAccessAtAddress:65
                                      length:1
                                       write:YES
                                   completed:&completed
                                       error:&error],
            error);
    assert(!completed);
    require([cache prepareCPUAccessAtAddress:65
                                      length:1
                                       write:YES
                                       error:&error],
            error);
    assert(surface.needsUpload && surface.scanoutClampToBorder);
    ((uint8_t *)vram.contents)[65] = 0x77;
    surface = [cache prepareSurfaceAtAddress:64 config:&c frame:3 error:&error];
    require(surface != nil, error);
    id<MTLBuffer> pixels = gpu_pixels(cache, surface);
    assert(((const uint32_t *)pixels.contents)[0] == 0x31317731);

    encode_vram_copy(cache, 512, 16);
    NV2AMetalSurfaceRecording *token = cache.recording;
    uint64_t before, after;
    require([cache sourceVersionAtAddress:3072
                                   length:4
                                  version:&before
                                    error:&error],
            error);
    require([cache tryIdleCPUAccessAtAddress:3072
                                      length:4
                                       write:YES
                                   completed:&completed
                                       error:&error],
            error);
    assert(completed);
    memset((uint8_t *)vram.contents + 3072, 0x55, 4);
    [cache cancel];
    require([cache sourceVersionAtAddress:3072
                                   length:4
                                  version:&after
                                    error:&error],
            error);
    assert(token.cancelled && after > before &&
           ((const uint8_t *)vram.contents)[3072] == 0x55);
    id<MTLBuffer> copy = encode_vram_copy(cache, 3072, 4);
    require([cache submitWithError:&error], error);
    require([cache waitUntilIdleWithError:&error], error);
    assert(((const uint32_t *)copy.contents)[0] == 0x55555555);
    require([cache flushWithError:&error], error);
    checks += 3;
    printf("Recorded surface CPU write and cancelled GPU/CPU version checks "
           "PASS\n");
}

#include "test-metal-cache-idle-guard.h"
#include "test-metal-dirty-notice.h"
#include "test-metal-independent-vram.h"
#include "test-metal-clean-surface-reader.h"

#include "test-metal-cpu-read-guard.h"


@interface RetirementFailureReceipt : NSObject
@property(nonatomic) BOOL ready;
@property(nonatomic) NSError *failure;
@end
@implementation RetirementFailureReceipt
- (BOOL)completedWithError:(NSError **)error
{
    if (error)
        *error = _ready ? _failure : nil;
    return _ready;
}
@end

static void retirement_failure_test(id<MTLDevice> device)
{
    NSError *error = nil;
    CacheFailureCommands *commands =
        [[CacheFailureCommands alloc] initWithDevice:device error:&error];
    require(commands != nil, error);
    RetirementFailureReceipt *receipt = [RetirementFailureReceipt new];
    receipt.failure = [NSError errorWithDomain:@"test.retirement"
                                          code:7
                                      userInfo:nil];
    commands.pollReceipt = receipt;
    id<MTLBuffer> ram =
        [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    assert(ram);
    NV2AMetalSurfaceCache *cache =
        [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                   vram:ram
                                           didWriteVRAM:nil
                                                  error:&error];
    require(cache != nil, error);
    require([cache prepareGPUReadAtAddress:0 length:4 error:&error], error);
    NV2AMetalSurfaceRecording *token = cache.recording;
    require([cache submitWithError:&error], error);
    require([cache collectCompletedWithError:&error], error);
    assert(!token.completed);
    /* Fault injection after actual GPU completion, never a live-resource race.
     */
    require([commands waitUntilIdleWithError:&error], error);
    receipt.ready = YES;
    assert(![cache collectCompletedWithError:&error] &&
           error == receipt.failure);
    assert(!token.completed &&
           !nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 0, 4, YES));
    assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 2048, 4, NO));
    assert(![cache prepareGPUReadAtAddress:0 length:4 error:&error]);
    assert(![cache collectCompletedWithError:&error] &&
           error == receipt.failure);
    puts("Metal4 retirement failure injection: no token completion, sticky "
         "cache failure and CPU guard closed PASS");
    checks++;
}

static void encode_raw_copy(NV2AMetalSurfaceCache *cache, NSUInteger source,
                            NSUInteger destination)
{
    NSError *error = nil;
    require([cache prepareGPUReadAtAddress:source length:4 error:&error],
            error);
    require([cache prepareGPUWriteAtAddress:destination length:4 error:&error],
            error);
    id<MTL4ComputeCommandEncoder> encoder =
        [cache.commands.commandBuffer computeCommandEncoder];
    assert(encoder);
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder copyFromBuffer:cache.vram
               sourceOffset:source
                   toBuffer:cache.vram
          destinationOffset:destination
                       size:4];
    [encoder barrierAfterStages:MTLStageBlit
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
}

static void submission_retirement_tests(id<MTLDevice> device)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(commands != nil, error);
    id<MTLBuffer> ram =
        [device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    assert(ram);
    memset(ram.contents, 0, ram.length);
    ((uint32_t *)ram.contents)[4096 / 4] = 0x12345678;
    NSThread *owner = NSThread.currentThread;
    __block unsigned notifications = 0;
    NV2AMetalSurfaceCache *cache = [[NV2AMetalSurfaceCache alloc]
        initWithCommands:commands
                    vram:ram
            didWriteVRAM:^(NSUInteger address, NSUInteger length) {
              assert(NSThread.currentThread == owner && address == 0 && length);
              notifications++;
            }
                   error:&error];
    require(cache != nil, error);
    NV2AMetalSurfaceConfig c =
        config(NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8, YES, 4, 1, NO);
    NV2AMetalCachedSurface *surface = [cache prepareSurfaceAtAddress:0
                                                              config:&c
                                                               frame:0
                                                               error:&error];
    require(surface != nil, error);
    clear_surface(cache, surface, MTLClearColorMake(1, 0, 0, 1), 0, 0);
    require([cache markWritten:surface error:&error], error);
    require([cache prepareGPUReadAtAddress:0 length:128 error:&error], error);
    require([cache prepareGPUReadAtAddress:4096 length:4 error:&error], error);
    require([cache prepareGPUReadAtAddress:8192 length:4 error:&error], error);
    encode_raw_copy(cache, 4096, 24576);
    NV2AMetalSurfaceRecording *first = cache.recording;
    id<MTLSharedEvent> firstGate = [device newSharedEvent];
    id<MTLSharedEvent> secondGate = [device newSharedEvent];
    assert(firstGate && secondGate);
    Ivar ivar = class_getInstanceVariable(NV2AMetalCommands.class, "_queue");
    id<MTL4CommandQueue> queue = object_getIvar(commands, ivar);
    [queue waitForEvent:firstGate value:1];
    require([cache submitWithError:&error], error);
    NV2AMetalSubmission *firstReceipt = commands.lastSubmitted;
    require([cache prepareGPUReadAtAddress:8192 length:4 error:&error], error);
    id<MTLBuffer> secondCopy = encode_vram_copy(cache, 12288, 4);
    encode_raw_copy(cache, 12288, 32768);
    NV2AMetalSurfaceRecording *second = cache.recording;
    /* Obtain first feedback before submitting the deliberately blocked second
     * workload. Drivers may batch feedback delivery behind queued work. */
    firstGate.signaledValue = 1;
    for (unsigned i = 0; i < 5000 && ![firstReceipt completedWithError:&error]; i++)
        usleep(1000);
    assert([firstReceipt completedWithError:&error] && !error);
    assert(!first.completed && !notifications);
    [queue waitForEvent:secondGate value:1];
    require([cache submitWithError:&error], error);
    NV2AMetalSubmission *secondReceipt = commands.lastSubmitted;
    assert(![secondReceipt completedWithError:&error]);
    assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 4096, 4, YES));
    require([cache waitForSubmission:firstReceipt error:&error], error);
    assert(first.completed && !second.completed && notifications == 1);
    /* A third recording must remain protected during repeated collection. */
    require([cache prepareGPUReadAtAddress:16384 length:4 error:&error], error);
    NV2AMetalSurfaceRecording *pending = cache.recording;
    id recording = commands.commandBuffer;
    require([cache waitForSubmission:firstReceipt error:&error], error);
    assert(first.completed && !second.completed && !pending.completed);
    assert(notifications == 1 && cache.recording == pending &&
           commands.commandBuffer == recording);
    NV2AMetalCommands *foreign =
        [[NV2AMetalCommands alloc] initWithDevice:device error:&error];
    require(foreign != nil, error);
    require([foreign beginWithError:&error] != nil, error);
    require([foreign submitWithError:&error], error);
    assert(![cache waitForSubmission:foreign.lastSubmitted error:&error] &&
           error);
    assert(cache.recording == pending && commands.commandBuffer == recording &&
           ![secondReceipt completedWithError:&error]);
    assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 4096, 4, YES));
    assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 8192, 4, YES));
    assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 12288, 4, YES));
    assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 16384, 4, YES));
    assert(*(uint32_t *)ram.contents == 0xffff0000u);
    BOOL idle = NO;
    require([cache tryIdleCPUAccessAtAddress:24576
                                      length:4
                                       write:NO
                                   completed:&idle
                                       error:&error],
            error);
    assert(idle && ((uint32_t *)ram.contents)[24576 / 4] == 0x12345678);
    require([cache tryIdleCPUAccessAtAddress:32768
                                      length:4
                                       write:NO
                                   completed:&idle
                                       error:&error],
            error);
    assert(!idle);
    require([cache collectCompletedWithError:&error], error);
    assert(notifications == 1);
    [cache cancel];
    assert(pending.cancelled && !pending.completed);
    assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 16384, 4, YES));
    secondGate.signaledValue = 1;
    require([cache waitUntilIdleWithError:&error], error);
    require([foreign waitUntilIdleWithError:&error], error);
    assert(second.completed && notifications == 1);
    assert(*(uint32_t *)secondCopy.contents == 0);
    assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 8192, 4, YES));
    assert(nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 12288, 4, YES));
    /* Automatic owner collection at the next recording boundary. */
    for (unsigned i = 0; i < 8; i++) {
        require([cache prepareGPUReadAtAddress:4096 length:4 error:&error],
                error);
        NV2AMetalSurfaceRecording *token = cache.recording;
        require([cache submitWithError:&error], error);
        NV2AMetalSubmission *receipt = commands.lastSubmitted;
        for (unsigned spin = 0;
             spin < 5000 && ![receipt completedWithError:&error]; spin++)
            usleep(1000);
        assert([receipt completedWithError:&error] && !error);
        require([cache prepareGPUReadAtAddress:16384 length:4 error:&error],
                error);
        assert(token.completed &&
               nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 4096, 4, YES));
        [cache cancel];
    }
    require([cache flushWithError:&error], error);
    puts("Metal4 per-submission retirement: first source/download released "
         "while "
         "second GPU submission gated; overlapping/pending readers protected; "
         "specific/repeated waits with a live later recording,foreign receipt "
         "rejected,owner callback once,cancel and eight slot rotations PASS");
    checks++;
}

#include "test-metal-submission-prefix.h"

static void specific_wait_failure_test(id<MTLDevice> device)
{
    for (unsigned missingError = 0; missingError < 2; missingError++) {
        NSError *error = nil;
        CacheFailureCommands *commands =
            [[CacheFailureCommands alloc] initWithDevice:device error:&error];
        require(commands != nil, error);
        id<MTLBuffer> ram =
            [device newBufferWithLength:8192
                                options:MTLResourceStorageModeShared];
        assert(ram);
        NV2AMetalSurfaceCache *cache =
            [[NV2AMetalSurfaceCache alloc] initWithCommands:commands
                                                       vram:ram
                                               didWriteVRAM:nil
                                                      error:&error];
        require(cache != nil, error);
        require([cache prepareGPUReadAtAddress:0 length:4 error:&error], error);
        NV2AMetalSurfaceRecording *submitted = cache.recording;
        require([cache submitWithError:&error], error);
        NV2AMetalSubmission *receipt = commands.lastSubmitted;
        require([cache prepareGPUReadAtAddress:4096 length:4 error:&error],
                error);
        NV2AMetalSurfaceRecording *pending = cache.recording;
        commands.failCompletion = YES;
        commands.omitCompletionError = missingError;
        assert(![cache waitForSubmission:receipt error:&error] && error);
        assert(!nv2a_metal_try_cpu_access(cache.cpuAccessGuard, 0, ram.length,
                                          YES));
        assert(![cache collectCompletedWithError:&error] && error);
        assert(cache.recording == pending && !pending.submitted &&
               !pending.cancelled && submitted.submitted);
        [cache cancel];
        assert(pending.cancelled && !pending.completed);
        puts("Surface specific wait:injected completion failure is sticky,"
             "with/without diagnostics,CPU guard rejects access and later "
             "recording remains cancellable "
             "PASS");
        checks++;
    }
}

#include "test-metal-cache-checkpoints.h"
#include "test-metal-surface-capture.h"
#include "test-metal-parallel-surface-readers.h"
#include "test-metal-gpu-write-dependencies.h"
#include "test-metal-execution-publication.h"
#include "test-metal-reader-publication.h"
#include "test-metal-strided-reads.h"

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        if (argc == 2 && !strcmp(argv[1], "--strided-reads")) {
            strided_read_tests(commands.device);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--reader-publication")) {
            reader_publication_tests(commands.device);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--execution-publication")) {
            execution_publication_tests(commands.device);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--GPU-write-dependencies")) {
            gpu_write_dependency_tests(commands.device);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--parallel-surface-readers")) {
            parallel_surface_reader_tests(commands.device);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--capture-only")) {
            surface_capture_tests(commands.device);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--checkpoints")) {
            cache_checkpoint_tests(commands.device);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--clean-alias")) {
            clean_surface_reader_tests(commands.device);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--independent-vram")) {
            independent_vram_tests(commands.device);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--dirty-notice")) {
            dirty_notice_tests(commands.device);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--CPU-read-guard")) {
            cpu_read_guard_tests(commands.device);
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--CPU-GPU-wait")) {
            cache_idle_guard_tests(commands.device);
            return 0;
        }

        id<MTLBuffer> vram =
            [commands.device newBufferWithLength:4096
                                         options:MTLResourceStorageModeShared];
        assert(vram);
        gpu_write_dependency_tests(commands.device);
        execution_publication_tests(commands.device);
        reader_publication_tests(commands.device);
        parallel_surface_reader_tests(commands.device);
        strided_read_tests(commands.device);
        surface_capture_tests(commands.device);
        cache_checkpoint_tests(commands.device);
        retirement_failure_test(commands.device);
        submission_retirement_tests(commands.device);
        specific_wait_failure_test(commands.device);
        submission_prefix_tests(commands.device);
        cpu_read_guard_tests(commands.device);
        raw_GPU_write_range_tests(commands, vram);
        recording_write_tests(commands, vram);
        transfer_write_range_tests(commands, vram);
        cpu_write_range_tests(commands, vram);
        idle_cpu_access_tests(commands, vram);
        active_cpu_read_tests(commands, vram);
        coherence_tests(commands, vram);
        cancel_tests(commands, vram);
        overlap_tests(commands, vram);
        depth_encoding_alias(commands, vram);
        replacement_tests(commands, vram);
        eviction_and_restore_tests(commands, vram);
        format_tests(commands, vram);
        rejection_tests(commands, vram);
        failure_and_lifetime_tests(commands.device);
        cache_idle_guard_tests(commands.device);
        dirty_notice_tests(commands.device);
        independent_vram_tests(commands.device);
        clean_surface_reader_tests(commands.device);
        printf("Metal 4 surface cache: %u coherence checks PASS\n", checks);
    }
    return 0;
}
