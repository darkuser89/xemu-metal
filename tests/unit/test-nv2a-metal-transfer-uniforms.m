/* Queued clear/blit/surface uniforms against dedicated immutable uploads.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "hw/xbox/nv2a/pgraph/metal/clear.h"
#import "hw/xbox/nv2a/pgraph/metal/blit.h"
#import "hw/xbox/nv2a/pgraph/metal/surface-transfer.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Transfer uniforms: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}

@interface TransferUniformCommands : NV2AMetalCommands
@property(nonatomic) BOOL dedicated, failUpload;
@property(nonatomic) unsigned recursion, nonzero;
@property(nonatomic) NSUInteger copied;
@property(nonatomic) NSMutableArray *uploads;
@property(nonatomic) NSHashTable *buffers;
@end
@implementation TransferUniformCommands
- (id<MTLBuffer>)uploadBytes:(const void *)bytes
                      length:(NSUInteger)length
                      offset:(NSUInteger *)offset
                       error:(NSError **)error
{
    if (_failUpload) {
        if (error)
            *error = [NSError errorWithDomain:@"transfer-uniform-injection"
                                         code:1
                                     userInfo:nil];
        return nil;
    }
    _recursion++;
    id<MTLBuffer> result;
    if (_dedicated) {
        result = [self.device newBufferWithBytes:bytes
                                          length:length
                                         options:MTLResourceStorageModeShared];
        if (result && ![self addResource:result error:error])
            result = nil;
        *offset = 0;
    } else {
        result = [super uploadBytes:bytes
                             length:length
                             offset:offset
                              error:error];
    }
    _recursion--;
    if (result && !_recursion) {
        assert(*offset % 256 == 0);
        _nonzero += *offset != 0;
        _copied += length;
        [_buffers addObject:result];
        [_uploads addObject:@[
            result, @(*offset), [NSData dataWithBytes:bytes length:length]
        ]];
    }
    return result;
}
@end

@interface TransferUniformOutput : NSObject
@property(nonatomic) id<MTLBuffer> before, after, blit;
@property(nonatomic) NV2AMetalBlitConfig config;
@property(nonatomic) BOOL alias;
@property(nonatomic, weak) NV2AMetalSurfaceTransfer *surface;
@end
@implementation TransferUniformOutput
@end

static void finish(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
}
static void copy_buffer(NV2AMetalCommands *commands, id<MTLBuffer> from,
                        id<MTLBuffer> to)
{
    NSError *error = nil;
    require([commands addResource:from error:&error] &&
                [commands addResource:to error:&error],
            error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:from
             sourceOffset:0
                 toBuffer:to
        destinationOffset:0
                     size:from.length];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
}

/* Each instance goes out of local scope before submission. Commands must
 * keep the surface, argument table, pipelines and arena slices alive. */
static TransferUniformOutput *encode_case(TransferUniformCommands *commands,
                                          NV2AMetalClear *clearer,
                                          NV2AMetalBlit *blitter,
                                          unsigned round, unsigned test)
{
    const unsigned formats[] = {
        NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5,
        NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5,
        NV097_SET_SURFACE_FORMAT_ZETA_Z16,
        NV097_SET_SURFACE_FORMAT_ZETA_Z16,
        NV097_SET_SURFACE_FORMAT_ZETA_Z24S8
    };
    unsigned kind = test % 8, bytes = kind == 1              ? 1 :
                                      kind == 0 || kind == 7 ? 4 :
                                                               2;
    NV2AMetalSurfaceConfig config = {
        .format = formats[kind],
        .width = 8,
        .height = 8,
        .pitch = 8 * bytes + 8,
        .scale = 1 + (test / 8) % 2,
        .color = kind < 5,
        .swizzle = (test / 16) & 1,
        .floating_depth = kind == 6 || (kind == 7 && (round & 1))
    };
    NSError *error = nil;
    NV2AMetalSurfaceTransfer *surface =
        [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                  config:&config
                                                   error:&error];
    require(surface != nil, error);
    id<MTLBuffer> source =
        [commands.device newBufferWithLength:1024
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:1024
                                     options:MTLResourceStorageModeShared];
    id<MTLBuffer> before =
        [commands.device newBufferWithLength:1024
                                     options:MTLResourceStorageModeShared];
    assert(source && output && before);
    memset(before.contents, 0x3c, before.length);
    for (unsigned i = 0; i < 1024; i++)
        ((uint8_t *)source.contents)[i] =
            (i * 73 + test * 29 + round * 19) & 255;
    memset(output.contents, 0xa5, output.length);
    require([surface encodeUploadFromBuffer:source
                                     offset:3
                                   commands:commands
                                      error:&error],
            error);
    const unsigned channels[] = { NV097_CLEAR_SURFACE_R, NV097_CLEAR_SURFACE_G,
                                  NV097_CLEAR_SURFACE_B,
                                  NV097_CLEAR_SURFACE_A };
    NV2AMetalClearConfig clear = {
        .rect = { (test / 3) % 4, (test / 5) % 4, 3 + test % 7, 3 + test % 5 },
        .parameter = config.color ?
                         channels[test % 4] | channels[(test + 1) % 4] :
                         NV097_CLEAR_SURFACE_Z |
                             (test & 1 ? NV097_CLEAR_SURFACE_STENCIL : 0),
        .stencil = test * 23 + round,
        .dither = (test & 1) != 0,
        .uniforms = { .color = { (test % 17) / 16.f, .25f, .5f, .75f },
                      .depth = (test + round + 1) / 64.f }
    };
    require([clearer encodeColor:config.color ? surface.texture : nil
                            zeta:config.color ? nil : surface.texture
                          config:&clear
                        commands:commands
                           error:&error],
            error);
    require([surface encodeDownloadToBuffer:output
                                     offset:5
                                    swizzle:config.swizzle
                                       flip:(test & 1) != 0
                                  downscale:YES
                                   commands:commands
                                      error:&error],
            error);
    copy_buffer(commands, output, before);
    BOOL alias = (test & 2) != 0;
    id<MTLBuffer> dest =
        alias ?
            output :
            [commands.device newBufferWithLength:1024
                                         options:MTLResourceStorageModeShared];
    assert(dest);
    if (!alias)
        memset(dest.contents, 0xa5, dest.length);
    const unsigned blitFormats[] = {
        NV062_SET_COLOR_FORMAT_LE_Y8, NV062_SET_COLOR_FORMAT_LE_R5G6B5,
        NV062_SET_COLOR_FORMAT_LE_A8R8G8B8, NV062_SET_COLOR_FORMAT_LE_X8R8G8B8,
        NV062_SET_COLOR_FORMAT_LE_X8R8G8B8_Z8R8G8B8
    };
    NV2AMetalBlitConfig blit = {
        .format = blitFormats[(test / 3) % 5],
        .operation = test & 1 ? NV09F_SET_OPERATION_BLEND_AND :
                                NV09F_SET_OPERATION_SRCCOPY,
        .source_offset = 12,
        .destination_offset = alias ? (test & 4 ? 8 : 16) : 20,
        .source_pitch = 40,
        .destination_pitch = 40,
        .row_bytes = 16 + test % 3 * 4,
        .rows = 3,
        .tail_bytes = test % 5 * 4,
        .beta = ((test * 317 + round * 71) % 32641) << 16
    };
    require([blitter encodeSource:output
                      destination:dest
                           config:&blit
                         commands:commands
                            error:&error],
            error);
    TransferUniformOutput *result = [TransferUniformOutput new];
    result.before = before;
    result.after = output;
    result.blit = dest;
    result.config = blit;
    result.alias = alias;
    result.surface = surface;
    return result;
}

static void blit_oracle(TransferUniformOutput *o)
{
    NV2AMetalBlitConfig c = o.config;
    NSMutableData *expected = [NSMutableData dataWithLength:1024];
    if (o.alias)
        memcpy(expected.mutableBytes, o.before.contents, 1024);
    else
        memset(expected.mutableBytes, 0xa5, 1024);
    uint8_t *dest = expected.mutableBytes;
    const uint8_t *source = o.alias ? dest : o.before.contents;
    unsigned bytes = c.format == NV062_SET_COLOR_FORMAT_LE_Y8     ? 1 :
                     c.format == NV062_SET_COLOR_FORMAT_LE_R5G6B5 ? 2 :
                                                                    4;
    for (unsigned y = 0; y < c.rows + (c.tail_bytes != 0); y++) {
        unsigned length = y < c.rows ? c.row_bytes : c.tail_bytes;
        const uint8_t *s = source + c.source_offset + y * c.source_pitch;
        uint8_t *d = dest + c.destination_offset + y * c.destination_pitch;
        if (c.operation == NV09F_SET_OPERATION_SRCCOPY)
            memmove(d, s, length);
        else
            for (unsigned x = 0; x < length / bytes; x++)
                for (unsigned ch = 0; ch < 3; ch++) {
                    unsigned beta = c.beta >> 16;
                    d[x * 4 + ch] = (s[x * 4 + ch] * beta +
                                     d[x * 4 + ch] * (0x7f80 - beta)) /
                                    0x7f80;
                }
    }
    if (c.format == NV062_SET_COLOR_FORMAT_LE_X8R8G8B8 ||
        c.format == NV062_SET_COLOR_FORMAT_LE_X8R8G8B8_Z8R8G8B8)
        for (unsigned y = 0; y < c.rows + (c.tail_bytes != 0); y++)
            for (unsigned x = 0;
                 x < (y < c.rows ? c.row_bytes : c.tail_bytes) / 4; x++)
                dest[c.destination_offset + y * c.destination_pitch + x * 4 +
                     3] =
                    c.format == NV062_SET_COLOR_FORMAT_LE_X8R8G8B8 ? 255 : 0;
    assert(!memcmp(expected.bytes, o.blit.contents, 1024));
}

static void verify_uniforms(TransferUniformCommands *commands)
{
    for (NSArray *slice in commands.uploads) {
        id<MTLBuffer> buffer = slice[0];
        NSData *data = slice[2];
        assert(
            !memcmp((char *)buffer.contents + [slice[1] unsignedIntegerValue],
                    data.bytes, data.length));
    }
}

static void cancellation_and_failures(TransferUniformCommands *commands,
                                      NV2AMetalClear *clearer,
                                      NV2AMetalBlit *blitter)
{
    NSError *error = nil;
    commands.uploads = [NSMutableArray new];
    commands.buffers = [NSHashTable
        hashTableWithOptions:NSPointerFunctionsStrongMemory |
                             NSPointerFunctionsObjectPointerPersonality];
    require([commands beginWithError:&error] != nil, error);
    TransferUniformOutput *cancelled;
    @autoreleasepool {
        cancelled = encode_case(commands, clearer, blitter, 0, 3);
    }
    assert(cancelled.surface && commands.uploads.count == 4);
    [commands cancel];
    assert(!cancelled.surface);
    for (unsigned i = 0; i < 1024; i++) {
        assert(((uint8_t *)cancelled.before.contents)[i] == 0x3c);
        assert(((uint8_t *)cancelled.after.contents)[i] == 0xa5);
        assert(((uint8_t *)cancelled.blit.contents)[i] == 0xa5);
    }
    commands.uploads = [NSMutableArray new];
    require([commands beginWithError:&error] != nil, error);
    TransferUniformOutput *retry;
    @autoreleasepool {
        retry = encode_case(commands, clearer, blitter, 0, 3);
    }
    finish(commands);
    assert(!retry.surface);
    blit_oracle(retry);

    for (unsigned failure = 0; failure < 6; failure++) {
        @autoreleasepool {
            NV2AMetalSurfaceConfig config = {
                .format =
                    failure == 4 ? NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5 :
                    failure == 5 ? NV097_SET_SURFACE_FORMAT_ZETA_Z24S8 :
                                   NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8,
                .width = 8,
                .height = 8,
                .pitch = 32,
                .scale = 1,
                .color = failure != 5
            };
            NV2AMetalSurfaceTransfer *surface =
                [[NV2AMetalSurfaceTransfer alloc] initWithDevice:commands.device
                                                          config:&config
                                                           error:&error];
            require(surface != nil, error);
            id<MTLBuffer> data = [commands.device
                newBufferWithLength:1024
                            options:MTLResourceStorageModeShared];
            assert(data);
            memset(data.contents, 0x6b, data.length);
            NV2AMetalClearConfig clear = {
                .rect = { 0, 0, 8, 8 },
                .parameter = config.color ? NV097_CLEAR_SURFACE_COLOR :
                                            NV097_CLEAR_SURFACE_Z,
                .uniforms = { .color = { .25f, .5f, .75f, 1 } }
            };
            NV2AMetalBlitConfig blit = { .format =
                                             NV062_SET_COLOR_FORMAT_LE_A8R8G8B8,
                                         .operation =
                                             NV09F_SET_OPERATION_SRCCOPY,
                                         .source_pitch = 32,
                                         .destination_pitch = 32,
                                         .row_bytes = 16,
                                         .rows = 2 };
            require([commands beginWithError:&error] != nil, error);
            commands.uploads = [NSMutableArray new];
            /* Empty operations and pre-encode validation need no upload. */
            clear.rect.width = 0;
            require([clearer encodeColor:config.color ? surface.texture : nil
                                    zeta:config.color ? nil : surface.texture
                                  config:&clear
                                commands:commands
                                   error:&error],
                    error);
            clear.rect.width = 8;
            NV2AMetalBlitConfig empty = blit;
            empty.rows = 0;
            require([blitter encodeSource:data
                              destination:data
                                   config:&empty
                                 commands:commands
                                    error:&error],
                    error);
            assert(![surface encodeUploadFromBuffer:data
                                             offset:data.length
                                           commands:commands
                                              error:&error]);
            assert(!commands.uploads.count);
            commands.failUpload = YES;
            error = nil;
            BOOL accepted;
            if (failure == 0)
                accepted = [clearer encodeColor:surface.texture
                                           zeta:nil
                                         config:&clear
                                       commands:commands
                                          error:&error];
            else if (failure == 1)
                accepted = [blitter encodeSource:data
                                     destination:data
                                          config:&blit
                                        commands:commands
                                           error:&error];
            else if (failure == 2)
                accepted = [surface encodeUploadFromBuffer:data
                                                    offset:3
                                                  commands:commands
                                                     error:&error];
            else
                accepted = [surface encodeDownloadToBuffer:data
                                                    offset:5
                                                   swizzle:NO
                                                      flip:NO
                                                 downscale:YES
                                                  commands:commands
                                                     error:&error];
            assert(
                !accepted && !commands.uploads.count &&
                [error.domain isEqualToString:@"transfer-uniform-injection"]);
            [commands cancel];
            commands.failUpload = NO;
            for (unsigned i = 0; i < 1024; i++)
                assert(((uint8_t *)data.contents)[i] == 0x6b);
            require([commands beginWithError:&error] != nil, error);
            @autoreleasepool {
                retry = encode_case(commands, clearer, blitter, 0, failure);
            }
            assert(retry.surface);
            finish(commands);
            assert(!retry.surface);
            blit_oracle(retry);
        }
    }
    commands.uploads = nil;
    commands.buffers = nil;
    puts("Metal4 transfer uniforms: cancellation leaves all three buffers "
         "intact,"
         "six upload failures retain errors/no writes,empty/span guards,"
         "seven GPU retries and owner release after cancel/completion PASS");
}

int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        TransferUniformCommands *arena =
            [[TransferUniformCommands alloc] initWithError:&error];
        require(arena != nil, error);
        TransferUniformCommands *dedicated =
            [[TransferUniformCommands alloc] initWithDevice:arena.device
                                                      error:&error];
        require(dedicated != nil, error);
        dedicated.dedicated = YES;
        NV2AMetalClear *clearer =
            [[NV2AMetalClear alloc] initWithDevice:arena.device error:&error];
        NV2AMetalBlit *blitter =
            [[NV2AMetalBlit alloc] initWithDevice:arena.device error:&error];
        require(clearer && blitter, error);
        NSHashTable *pages = [NSHashTable
            hashTableWithOptions:NSPointerFunctionsStrongMemory |
                                 NSPointerFunctionsObjectPointerPersonality];
        NSUInteger pairs = 0, arenaUses = 0, dedicatedUses = 0, copied = 0,
                   nonzero = 0;
        for (unsigned round = 0; round < 5; round++) {
            @autoreleasepool {
                NSMutableArray *results[2] = { [NSMutableArray new],
                                               [NSMutableArray new] };
                for (TransferUniformCommands *commands in
                     @[ arena, dedicated ]) {
                    commands.uploads = [NSMutableArray new];
                    commands.buffers = [NSHashTable
                        hashTableWithOptions:
                            NSPointerFunctionsStrongMemory |
                            NSPointerFunctionsObjectPointerPersonality];
                    commands.copied = commands.nonzero = 0;
                    require([commands beginWithError:&error] != nil, error);
                    NSMutableData *padding =
                        [NSMutableData dataWithLength:65536 - 256];
                    memset(padding.mutableBytes, 0xbd, padding.length);
                    NSUInteger offset = 0;
                    require([commands uploadBytes:padding.bytes
                                           length:padding.length
                                           offset:&offset
                                            error:&error] != nil,
                            error);
                }
                for (unsigned test = 0; test < 48; test++)
                    for (unsigned mode = 0; mode < 2; mode++)
                        @autoreleasepool {
                            [results[mode]
                                addObject:encode_case(mode ? dedicated : arena,
                                                      clearer, blitter, round,
                                                      test)];
                        }
                assert(arena.uploads.count == 193 &&
                       dedicated.uploads.count == 193);
                assert(arena.copied == dedicated.copied && arena.nonzero > 180);
                assert(arena.buffers.count == 2 &&
                       dedicated.buffers.count == 193);
                for (TransferUniformCommands *commands in
                     @[ arena, dedicated ]) {
                    verify_uniforms(commands);
                    finish(commands);
                    verify_uniforms(commands);
                }
                for (unsigned test = 0; test < 48; test++) {
                    TransferUniformOutput *a = results[0][test],
                                          *b = results[1][test];
                    assert(!a.surface && !b.surface);
                    assert(!memcmp(a.before.contents, b.before.contents, 1024));
                    assert(!memcmp(a.after.contents, b.after.contents, 1024));
                    assert(!memcmp(a.blit.contents, b.blit.contents, 1024));
                    blit_oracle(a);
                    blit_oracle(b);
                    pairs++;
                }
                for (id page in arena.buffers)
                    [pages addObject:page];
                arenaUses += arena.buffers.count;
                dedicatedUses += dedicated.buffers.count;
                nonzero += arena.nonzero;
                copied += arena.copied;
                arena.uploads = dedicated.uploads = nil;
                arena.buffers = dedicated.buffers = nil;
            }
        }
        assert(pages.count == 6);
        cancellation_and_failures(arena, clearer, blitter);
        printf("Metal4 transfer uniforms: %lu exact queued "
               "upload/clear/download/blit pairs,"
               "five recordings/three slots; %lu distinct pages/%lu page uses "
               "vs %lu dedicated buffers,"
               "%lu nonzero offsets,%lu copied bytes per mode including "
               "rollover padding;"
               "480 full-buffer blit oracles PASS\n",
               (unsigned long)pairs, (unsigned long)pages.count,
               (unsigned long)arenaUses, (unsigned long)dedicatedUses,
               (unsigned long)nonzero, (unsigned long)copied);
    }
    return 0;
}
