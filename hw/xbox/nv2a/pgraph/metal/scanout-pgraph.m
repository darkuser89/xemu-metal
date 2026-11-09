/* Native scanout capture from gl/display.c; no CPU pixel conversion.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/display/vga_int.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "scanout-pgraph.h"
#import "texture-upload.h"
#import "vga.h"
#include <math.h>
static BOOL capture_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.scanout-capture"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}
@interface NV2AMetalScanoutTargetPool : NSObject
- (id<MTLTexture>)takeTexture:(MTLTextureDescriptor *)descriptor
                       device:(id<MTLDevice>)device;
- (void)recycleTexture:(id<MTLTexture>)texture;
@end

@implementation NV2AMetalScanoutTargetPool {
    NSMutableArray<id<MTLTexture>> *_free;
    NSUInteger _freeBytes;
}
- (instancetype)init
{
    self = [super init];
    if (self)
        _free = [NSMutableArray new];
    return self;
}
- (id<MTLTexture>)takeTexture:(MTLTextureDescriptor *)descriptor
                       device:(id<MTLDevice>)device
{
    @synchronized(self) {
        for (NSUInteger i = _free.count; i > 0; i--) {
            id<MTLTexture> texture = _free[i - 1];
            if (texture.pixelFormat == descriptor.pixelFormat &&
                texture.width == descriptor.width &&
                texture.height == descriptor.height &&
                texture.storageMode == descriptor.storageMode &&
                texture.usage == descriptor.usage) {
                _freeBytes -= texture.allocatedSize;
                [_free removeObjectAtIndex:i - 1];
                return texture;
            }
        }
    }
    return [device newTextureWithDescriptor:descriptor];
}
- (void)recycleTexture:(id<MTLTexture>)texture
{
    const NSUInteger byteLimit = 64 * 1024 * 1024;
    const NSUInteger targetLimit = 3;
    NSUInteger bytes = texture.allocatedSize;
    if (!bytes || bytes > byteLimit)
        return;
    @synchronized(self) {
        while (_free.count >= targetLimit || _freeBytes > byteLimit - bytes) {
            _freeBytes -= _free.firstObject.allocatedSize;
            [_free removeObjectAtIndex:0];
        }
        [_free addObject:texture];
        _freeBytes += bytes;
    }
}
@end

/* Palette-only publications share this lease. A retired scanout cannot
 * recycle its texture until the last publication/consumer is released. */
@interface NV2AMetalScanoutTargetLease : NSObject
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic, weak) NV2AMetalScanoutTargetPool *pool;
@end
@implementation NV2AMetalScanoutTargetLease
- (void)dealloc
{
    [_pool recycleTexture:_texture];
}
@end

@interface NV2AMetalFramebuffer ()
@property(nonatomic, readwrite) id<MTLTexture> texture;
@property(nonatomic, strong) NV2AMetalScanoutTargetLease *targetLease;
@property(nonatomic, readwrite) NV2AMetalDisplayUniforms displayUniforms;
@property(nonatomic, readwrite) BOOL screenOff;
@property(nonatomic) BOOL vgaBlank;
- (instancetype)initFrame;
- (BOOL)matchesPalette:(const uint8_t *)palette screenOff:(BOOL)screenOff;
@end
static uint32_t display_palette_entry(const uint8_t *rgb)
{
    return rgb[0] | (uint32_t)rgb[1] << 8 | (uint32_t)rgb[2] << 16;
}
@implementation NV2AMetalFramebuffer
- (instancetype)initFrame
{
    return [super init];
}
- (BOOL)matchesPalette:(const uint8_t *)palette screenOff:(BOOL)screenOff
{
    if (_screenOff != screenOff)
        return NO;
    for (unsigned i = 0; i < 256; i++)
        if (_displayUniforms.palette[i] != display_palette_entry(palette + 3 * i))
            return NO;
    return YES;
}
@end
static float pvideo_scale(uint32_t din_dout, uint32_t size)
{
    if (din_dout == NV_PVIDEO_DIN_DOUT_UNITY)
        return 1;
    /* GL multiplies uint32 BEFORE float conversion, including its wrap. */
    float calculated = (uint32_t)(din_dout * (size - 1));
    return (floorf(calculated / (1u << 20) + .5f) + 1) / size;
}

static gint vga_read_order(gconstpointer left, gconstpointer right)
{
    const NV2AMetalVRAMReadPattern *a = left, *b = right;
    if (a->stride != b->stride)
        return (a->stride > b->stride) - (a->stride < b->stride);
    if (a->stride) {
        NSUInteger a_lane = a->address % a->stride;
        NSUInteger b_lane = b->address % b->stride;
        if (a_lane != b_lane)
            return (a_lane > b_lane) - (a_lane < b_lane);
    }
    return (a->address > b->address) - (a->address < b->address);
}

/* The wrap is a power of two and contains a whole number of steps. */
static void vga_append_ring_reads(GArray *reads, uint32_t start,
                                  NSUInteger count, NSUInteger wrap,
                                  NSUInteger bias, NSUInteger step)
{
    NSUInteger lane = start & (step - 1);
    if (count >= wrap / step) {
        start = lane;
        count = wrap / step;
    } else {
        start &= wrap - 1;
    }
    NSUInteger head_count = MIN(count, 1 + (wrap - 1 - start) / step);
    NSUInteger stride = step == 1 ? 0 : step;
    NSUInteger element = stride ? 1 : 0;
    NV2AMetalVRAMReadPattern head = {
        bias + start, (head_count - 1) * step + 1, stride, element
    };
    g_array_append_val(reads, head);
    if (head_count < count) {
        NV2AMetalVRAMReadPattern tail = {
            bias + lane, (count - head_count - 1) * step + 1, stride, element
        };
        g_array_append_val(reads, tail);
    }
}

static GArray *vga_graphics_reads(const NV2AMetalVGAUniforms *u,
                                 const NV2AMetalVGARow *rows)
{
    GArray *reads = g_array_new(false, false,
                                sizeof(NV2AMetalVRAMReadPattern));
    bool planar = u->mode == 2 || u->mode == 4;
    if (u->mode == 255 || (planar && !u->plane_mask))
        return reads;

    NSUInteger window = (NSUInteger)u->memory_mask + 1;
    for (unsigned y = 0; y < u->height; y++) {
        uint32_t start = rows[y].address;
        NSUInteger length;
        NSUInteger wrap = window;
        NSUInteger bias = 0;
        switch (u->mode) {
        case 2:
        case 4: {
            start &= ~3u;
            wrap = MIN(window, 0x40000u);
            unsigned first = rows[y].hpel;
            unsigned last = first + (u->width - 1) / (u->duplicate ? 2 : 1);
            if (u->mode == 4 && (u->plane_mask & 15) == 15) {
                vga_append_ring_reads(reads, start + first / 8 * 4,
                                      (last / 8 - first / 8 + 1) * 4,
                                      wrap, 0, 1);
                continue;
            }
            for (unsigned plane = 0; plane < 4; plane++) {
                if (!(u->plane_mask & (1u << plane)))
                    continue;
                unsigned first_group = first / 8, last_group = last / 8;
                if (u->mode == 2) {
                    /* In CGA mode each plane serves one half of a group. */
                    unsigned phase = (plane & 1) * 4;
                    if (last < phase)
                        continue;
                    first_group = (first + 4 - phase) / 8;
                    last_group = (last - phase) / 8;
                    if (first_group > last_group)
                        continue;
                }
                vga_append_ring_reads(reads, start + first_group * 4 + plane,
                                      last_group - first_group + 1, wrap, 0,
                                      4);
            }
            continue;
        }
        case 0:
            wrap = MIN(window, 0x40000u);
            /* The shader wraps the four-byte group before adding the lane.
             * In a larger VRAM window the group misalignment shifts the
             * entire legacy ring, including bytes beyond its upper edge. */
            if (window > wrap)
                bias = start & 3;
            start = start - (uint32_t)bias + rows[y].hpel;
            length = (u->width + 1) / 2;
            break;
        case 8:
            start += rows[y].hpel;
            length = u->width;
            break;
        case 15:
        case 16:
            start &= ~1u;
            length = u->width * 2;
            break;
        case 24:
            length = u->width * 3;
            break;
        default: /* A 32-bit packed pixel skips the alpha lane. */
            for (unsigned channel = 0; channel < 3; channel++)
                vga_append_ring_reads(reads, start + u->big_endian + channel,
                                      u->width, wrap, 0, 4);
            continue;
        }
        vga_append_ring_reads(reads, start, length, wrap, bias, 1);
    }
    g_array_sort(reads, vga_read_order);
    unsigned merged = 0;
    for (unsigned i = 0; i < reads->len; i++) {
        NV2AMetalVRAMReadPattern span =
            g_array_index(reads, NV2AMetalVRAMReadPattern, i);
        if (merged) {
            NV2AMetalVRAMReadPattern *prior =
                &g_array_index(reads, NV2AMetalVRAMReadPattern, merged - 1);
            if (span.stride == prior->stride &&
                (!span.stride ||
                 (span.address - prior->address) % span.stride == 0) &&
                span.address <= prior->address + prior->length +
                                    prior->stride - prior->element) {
                prior->length =
                    MAX(prior->length, span.address - prior->address +
                                           span.length);
                continue;
            }
        }
        g_array_index(reads, NV2AMetalVRAMReadPattern, merged++) = span;
    }
    g_array_set_size(reads, merged);
    return reads;
}

static GArray *vga_text_reads(const NV2AMetalVGAUniforms *u,
                              const NV2AMetalVGARow *rows)
{
    unsigned ch = u->character_height;
    GArray *reads = g_array_sized_new(false, false,
                                    sizeof(NV2AMetalVRAMReadPattern),
                                    u->height / ch + 2 * ch);
    /* Each glyph row uses one byte in every possible character slot. */
    for (unsigned bank = 0; bank < 2; bank++) {
        if (bank && u->font_offset[0] == u->font_offset[1])
            break;
        for (unsigned glyph = 0; glyph < ch; glyph++) {
            NV2AMetalVRAMReadPattern font = {
                u->font_offset[bank] + glyph * 4, 255 * 128 + 1, 128, 1
            };
            g_array_append_val(reads, font);
        }
    }
    /* Glyph scanlines share the same character and attribute bytes. */
    for (unsigned y = 0; y < u->height; y += ch) {
        if (!y || rows[y - ch].address != rows[y].address) {
            NV2AMetalVRAMReadPattern cells = {
                rows[y].address, (u->text_columns - 1) * 4 + 2, 4, 2
            };
            g_array_append_val(reads, cells);
        }
    }
    return reads;
}

static int vga_span_order(const void *left, const void *right)
{
    const NV2AMetalVRAMReadSpan *a = left, *b = right;
    return (a->address > b->address) - (a->address < b->address);
}

static NSData *vga_version_spans(const GArray *reads)
{
    if (!reads->len)
        return [NSData data];
    NSMutableData *storage =
        [NSMutableData dataWithLength:reads->len * sizeof(NV2AMetalVRAMReadSpan)];
    NV2AMetalVRAMReadSpan *spans = storage.mutableBytes;
    for (unsigned i = 0; i < reads->len; i++) {
        NV2AMetalVRAMReadPattern read =
            g_array_index(reads, NV2AMetalVRAMReadPattern, i);
        spans[i] = (NV2AMetalVRAMReadSpan){ read.address, read.length };
    }
    qsort(spans, reads->len, sizeof(*spans), vga_span_order);
    /* VGA strides are at most 128 bytes, so every page of a pattern
     * is read. Coalesce across touched pages without filling unused pages. */
    unsigned used = 0;
    for (unsigned i = 0; i < reads->len; i++) {
        NV2AMetalVRAMReadSpan span = spans[i];
        if (used) {
            NV2AMetalVRAMReadSpan *last = &spans[used - 1];
            NSUInteger end = last->address + last->length;
            if (span.address / 4096 <= (end - 1) / 4096 + 1) {
                last->length = MAX(end, span.address + span.length) -
                               last->address;
                continue;
            }
        }
        spans[used++] = span;
    }
    storage.length = used * sizeof(*spans);
    return [storage copy];
}

@interface NV2AMetalPGRAPHScanout ()
@property(atomic, strong, readwrite, nullable) NV2AMetalFramebuffer *frame;
@end

@implementation NV2AMetalPGRAPHScanout {
    NV2AState *_d;
    NV2AMetalSurfaceCache *_cache;
    NV2AMetalTextureUpload *_upload;
    NV2AMetalVGA *_vga;
    NV2AMetalScanoutTargetPool *_targetPool;
    NSMutableDictionary<NSNumber *, NV2AMetalScanout *> *_pipelines;
    BOOL _diagnostics;
    uint64_t _diagnosticFrames;
    NV2AMetalCachedSurface *_lastSource;
    uint64_t _lastSourceGeneration, _lastSourceVersion;
    uint64_t _lastOverlayKey[6];
    NV2AMetalScanoutUniforms _lastUniforms;
    NSData *_lastVGARows;
    NV2AMetalVGAUniforms _lastVGAUniforms;
    NSData *_lastVGASpans;
    NSData *_lastVGAReads;
    uint64_t _lastVGAVersion;
    NV2AMetalSurfaceRecording *_pendingRecording;
    NV2AMetalFramebuffer *_pendingFrame;
    gint64 _pendingSince;
    BOOL _pendingInvalidated;
}
- (instancetype)initWithState:(NV2AState *)state
                        cache:(NV2AMetalSurfaceCache *)cache
                        error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    if (!state || !state->vram || cache.vram.contents != state->vram_ptr ||
        cache.vram.length != memory_region_size(state->vram)) {
        capture_error(error, @"Scanout capture requires live native VRAM");
        return nil;
    }
    _d = state;
    _diagnostics =
        g_strcmp0(g_getenv("XEMU_METAL4_DIAGNOSTICS"), "1") == 0;
    _cache = cache;
    _upload =
        [[NV2AMetalTextureUpload alloc] initWithDevice:cache.commands.device
                                                 error:error];
    _targetPool = [NV2AMetalScanoutTargetPool new];
    NV2AMetalScanoutTargetPool *pool = _targetPool;
    id<MTLDevice> device = cache.commands.device;
    _vga = [[NV2AMetalVGA alloc]
        initWithDevice:device
        targetAllocator:^id<MTLTexture>(MTLTextureDescriptor *descriptor) {
            return [pool takeTexture:descriptor device:device];
        }
        error:error];
    _pipelines = [NSMutableDictionary new];
    return _upload && _vga ? self : nil;
}
- (void)invalidate
{
    self.frame = nil;
    _lastSource = nil;
    _lastVGARows = nil;
    _lastVGASpans = nil;
    _lastVGAReads = nil;
    /* A submitted capture still owns its target after invalidation. */
    _pendingInvalidated = _pendingRecording != nil;
}
- (NV2AMetalFramebuffer *)frameForTexture:(id<MTLTexture>)texture
                                   lease:(NV2AMetalScanoutTargetLease *)lease
{
    NV2AMetalFramebuffer *frame = [[NV2AMetalFramebuffer alloc] initFrame];
    frame.texture = texture;
    frame.targetLease = lease;
    NV2AMetalDisplayUniforms display = { .scale = { 1, 1 } };
    for (unsigned i = 0; i < 256; i++)
        display.palette[i] = display_palette_entry(_d->puserdac.palette + 3 * i);
    frame.displayUniforms = display;
    frame.screenOff = !!(_d->vga.sr[VGA_SEQ_CLOCK_MODE] & VGA_SR01_SCREEN_OFF);
    return frame;
}
- (void)refreshMetadataForFrame:(NV2AMetalFramebuffer *)frame
{
    BOOL screenOff = !!(_d->vga.sr[VGA_SEQ_CLOCK_MODE] & VGA_SR01_SCREEN_OFF);
    if ([frame matchesPalette:_d->puserdac.palette screenOff:screenOff])
        return;
    NV2AMetalFramebuffer *updated =
        [self frameForTexture:frame.texture lease:frame.targetLease];
    updated.vgaBlank = frame.vgaBlank;
    self.frame = updated;
}
- (BOOL)submitTexture:(id<MTLTexture>)texture error:(NSError **)error
{
    NV2AMetalSurfaceRecording *recording = _cache.recording;
    if (!recording)
        return capture_error(error, @"Scanout capture requires a recording");
    if (![_cache submitWithError:error])
        return NO;
    _lastVGARows = nil;
    _lastVGASpans = nil;
    _lastVGAReads = nil;
    NV2AMetalScanoutTargetLease *lease = [NV2AMetalScanoutTargetLease new];
    lease.texture = texture;
    lease.pool = _targetPool;
    _pendingFrame = [self frameForTexture:texture lease:lease];
    _pendingRecording = recording;
    _pendingSince = g_get_monotonic_time();
    return YES;
}
- (BOOL)completeCaptureWaiting:(BOOL)wait error:(NSError **)error
{
    if (!_pendingRecording)
        return YES;
    /* The cache retires the ordered feedback prefix, including any GPU
     * reader dependencies. A finished texture alone does not prove it. */
    BOOL ok = wait ? [_cache waitForRecording:_pendingRecording error:error] :
                     [_cache collectCompletedThroughRecording:_pendingRecording
                                                          error:error];
    if (ok && !_pendingRecording.completed) {
        if (!wait &&
            g_get_monotonic_time() - _pendingSince < 30 * G_TIME_SPAN_SECOND)
            return YES;
        ok = capture_error(error, wait ? @"Missing completed Metal scanout" :
                                        @"Timed out waiting for Metal scanout");
    }
    if (!ok) {
        /* A failed wait may leave the target in use. Never recycle it. */
        _pendingFrame.targetLease.pool = nil;
        _lastSource = nil;
        _lastVGARows = nil;
        _lastVGASpans = nil;
        _lastVGAReads = nil;
    } else if (!_pendingInvalidated) {
        self.frame = _pendingFrame;
    }
    _pendingFrame = nil;
    _pendingRecording = nil;
    _pendingInvalidated = NO;
    return ok;
}
- (BOOL)preserveOpenSectionWithError:(NSError **)error
{
    /* Accept the caller's section before capture can cancel its own work.
     * Raster and VRAM dependencies can still submit this prefix when needed. */
    return [_cache checkpointWithError:error];
}
- (BOOL)captureVGARows:(const NV2AMetalVGARow *)rows
              uniforms:(const NV2AMetalVGAUniforms *)u
                 error:(NSError **)error
{
    NSUInteger rowBytes = (NSUInteger)u->height * sizeof(*rows);
    BOOL sameLayout = _lastVGARows.length == rowBytes &&
                      !memcmp(&_lastVGAUniforms, u, sizeof(*u)) &&
                      !memcmp(_lastVGARows.bytes, rows, rowBytes);
    NSData *spanData = _lastVGASpans;
    NSData *readData = _lastVGAReads;
    NSData *rowData = _lastVGARows;
    if (!sameLayout) {
        g_autoptr(GArray) reads =
            u->mode == 1 ? vga_text_reads(u, rows) : vga_graphics_reads(u, rows);
        NSUInteger readBytes = reads->len * sizeof(NV2AMetalVRAMReadPattern);
        spanData = vga_version_spans(reads);
        readData = [NSData dataWithBytes:reads->data length:readBytes];
        if (u->mode != 255)
            rowData = [NSData dataWithBytes:rows length:rowBytes];
    }
    const NV2AMetalVRAMReadSpan *spans = spanData.bytes;
    NSUInteger spanCount = spanData.length / sizeof(*spans);
    const NV2AMetalVRAMReadPattern *patterns = readData.bytes;
    NSUInteger patternCount = readData.length / sizeof(*patterns);
    uint64_t version = 0;
    if (spanCount && ![_cache sourceVersionForReadSpans:spans count:spanCount
                                               version:&version error:error])
        return NO;
    if (sameLayout && version == _lastVGAVersion) {
        BOOL ready = NO;
        if (![_cache tryIdleCPUReadSpans:spans count:spanCount completed:&ready
                                 error:error])
            return NO;
        /* A writer in a skipped byte lane can overlap the page spans
         * without changing any pixel this VGA mode actually reads. */
        if (!ready && ![_cache tryIdleGPUReadPatterns:patterns
                                               count:patternCount
                                           completed:&ready error:error])
            return NO;
        NV2AMetalFramebuffer *frame = ready ? self.frame : nil;
        if (frame) {
            [self refreshMetadataForFrame:frame];
            return YES;
        }
    }
    if (![self preserveOpenSectionWithError:error])
        return NO;
    BOOL ok = [_cache prepareGPUReadPatterns:patterns count:patternCount
                                       error:error];
    id<MTLTexture> texture = ok ? [_vga encodeData:_cache.vram
                                              rows:rows
                                          uniforms:u
                                          commands:_cache.commands
                                             error:error] :
                                  nil;
    if (!texture || ![self submitTexture:texture error:error]) {
        [_cache cancel];
        return NO;
    }
    _pendingFrame.vgaBlank = u->mode == 255;
    if (!_pendingFrame.vgaBlank) {
        _lastVGARows = rowData;
        _lastVGAUniforms = *u;
        _lastVGASpans = spanData;
        _lastVGAReads = readData;
        _lastVGAVersion = version;
    }
    return YES;
}
- (BOOL)renderTextWithParams:(VGADisplayParams)params error:(NSError **)error
{
    VGACommonState *s = &_d->vga;
    unsigned ch = (s->cr[VGA_CRTC_MAX_SCAN] & 31) + 1;
    unsigned cw =
        !(s->sr[VGA_SEQ_CLOCK_MODE] & VGA_SR01_CHAR_CLK_8DOTS) ? 9 : 8;
    if (s->sr[VGA_SEQ_CLOCK_MODE] & 8)
        cw = 16;
    unsigned columns = s->cr[VGA_CRTC_H_DISP] + 1;
    unsigned bottom = s->cr[VGA_CRTC_V_DISP_END] |
                      ((s->cr[VGA_CRTC_OVERFLOW] & 2) << 7) |
                      ((s->cr[VGA_CRTC_OVERFLOW] & 64) << 3);
    unsigned lines = s->cr[VGA_CRTC_V_TOTAL] == 100 ? 100 : (bottom + 1) / ch;
    if ((uint64_t)columns * lines <= 1 ||
        (uint64_t)columns * lines > CH_ATTR_SIZE) {
        self.frame = nil;
        return YES;
    }
    NV2AMetalVGAUniforms u = { .mode = 1,
                               .width = columns * cw,
                               .height = lines * ch,
                               .memory_mask = s->vbe_size_mask,
                               .text_columns = columns,
                               .character_width = cw,
                               .character_height = ch,
                               .line_graphics = !!(s->ar[VGA_ATC_MODE] & 4) };
    unsigned map = s->sr[VGA_SEQ_CHARACTER_MAP];
    u.font_offset[0] = (((map >> 4) & 1) | ((map << 1) & 6)) * 8192 * 4 + 2;
    u.font_offset[1] = (((map >> 5) & 1) | ((map >> 1) & 6)) * 8192 * 4 + 2;
    u.cursor_address =
        ((s->cr[VGA_CRTC_CURSOR_HI] << 8) | s->cr[VGA_CRTC_CURSOR_LO]) * 4;
    u.cursor_start = s->cr[VGA_CRTC_CURSOR_START] & 31;
    u.cursor_end = MIN(s->cr[VGA_CRTC_CURSOR_END] & 31, ch - 1);
    int64_t now = qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL);
    if (s->graphic_mode != 0) {
        s->graphic_mode = 0;
        s->cursor_blink_time = now;
    }
    if (now >= s->cursor_blink_time) {
        s->cursor_blink_time = now + (1000 * 2 * 16 / 60) / 2;
        s->cursor_visible_phase = !s->cursor_visible_phase;
    }
    u.cursor_visible =
        !(s->cr[VGA_CRTC_CURSOR_START] & 0x20) && s->cursor_visible_phase;
    for (unsigned i = 0; i < 16; i++) {
        unsigned v = s->ar[i];
        unsigned entry =
            s->ar[VGA_ATC_MODE] & 0x80 ?
                ((s->ar[VGA_ATC_COLOR_PAGE] & 15) << 4) | (v & 15) :
                ((s->ar[VGA_ATC_COLOR_PAGE] & 12) << 4) | (v & 63);
        u.palette[i] = c6_to_8(s->palette[entry * 3]) |
                       c6_to_8(s->palette[entry * 3 + 1]) << 8 |
                       c6_to_8(s->palette[entry * 3 + 2]) << 16 | 0xff000000;
    }
    g_autofree NV2AMetalVGARow *rows = g_new0(NV2AMetalVGARow, u.height);
    uint32_t offset = params.start_addr * 4;
    unsigned line = 0;
    for (unsigned y = 0; y < lines; y++) {
        for (unsigned glyph = 0; glyph < ch; glyph++)
            rows[y * ch + glyph] = (NV2AMetalVGARow){ offset, glyph };
        offset += params.line_offset;
        unsigned next = line + ch;
        if (line < params.line_compare && next >= params.line_compare)
            offset = 0;
        line = next;
    }
    return [self captureVGARows:rows uniforms:&u error:error];
}
- (BOOL)renderVGAWithWidth:(int)width
                    height:(int)height
                    params:(VGADisplayParams)params
                     error:(NSError **)error
{
    VGACommonState *s = &_d->vga;
    if (!s->get_bpp || width <= 0 || height <= 0) {
        self.frame = nil;
        return YES;
    }
    if ((s->ar_index & 0x20) &&
        !(s->gr[VGA_GFX_MISC] & VGA_GR06_GRAPHICS_MODE)) {
        return [self renderTextWithParams:params error:error];
    }
    s->graphic_mode = (s->ar_index & 0x20) ? 1 : 2;
    if (width > 16384 || height > 16384)
        return capture_error(error, @"Invalid raw VGA resolution");
    NV2AMetalVGAUniforms u = { .width = (unsigned)width,
                               .height = (unsigned)height,
                               .memory_mask = s->vbe_size_mask,
                               .plane_mask = s->ar[VGA_ATC_PLANE_ENABLE] & 15,
                               .big_endian = s->big_endian_fb };
    unsigned shift = (s->gr[VGA_GFX_MODE] >> 5) & 3;
    int bpp = s->get_bpp(s);
    if (!(s->ar_index & 0x20))
        u.mode = 255;
    else if (shift == 0 || shift == 1) {
        u.mode = shift ? 2 : 4;
        u.duplicate = !!(s->sr[VGA_SEQ_CLOCK_MODE] & 8);
        if (u.duplicate)
            u.width *= 2;
    } else
        u.mode =
            (bpp == 8 || bpp == 15 || bpp == 16 || bpp == 24 || bpp == 32) ?
                (unsigned)bpp :
                0;
    if (u.width > 16384 || (u.mode <= 8 && width % 8))
        return capture_error(error, @"Invalid VGA planar width");
    NSUInteger window = (NSUInteger)u.memory_mask + 1;
    if (window < 4 || (window & (window - 1)) || window > _cache.vram.length)
        return capture_error(error, @"Invalid VGA graphics VRAM window");
    if (u.mode == 255) {
        NV2AMetalFramebuffer *frame = self.frame;
        /* Blank VGA emits opaque black independently of VRAM or palette. */
        if (frame.vgaBlank && frame.texture.width == u.width &&
            frame.texture.height == u.height) {
            if (![_cache collectCompletedWithError:error])
                return NO;
            [self refreshMetadataForFrame:frame];
            return YES;
        }
    }
    for (unsigned i = 0; i < 256; i++) {
        unsigned entry = i;
        if (u.mode == 2 || u.mode == 4) {
            unsigned v = s->ar[i & 15];
            entry = s->ar[VGA_ATC_MODE] & 0x80 ?
                        ((s->ar[VGA_ATC_COLOR_PAGE] & 15) << 4) | (v & 15) :
                        ((s->ar[VGA_ATC_COLOR_PAGE] & 12) << 4) | (v & 63);
        }
        unsigned color = 0;
        for (unsigned k = 0; k < 3; k++) {
            unsigned value = s->palette[entry * 3 + k];
            if (u.mode == 2 || u.mode == 4 || !s->dac_8bit)
                value = c6_to_8(value);
            color |= value << (8 * k);
        }
        u.palette[i] = color | 0xff000000;
    }
    g_autofree NV2AMetalVGARow *rows = g_new0(NV2AMetalVGARow, height);
    uint32_t addr = params.start_addr * 4, y1 = 0;
    unsigned double_scan = s->cr[VGA_CRTC_MAX_SCAN] >> 7;
    unsigned multi =
        s->cr[VGA_CRTC_MODE] & 1 ?
            (((s->cr[VGA_CRTC_MAX_SCAN] & 31) + 1) << double_scan) - 1 :
            double_scan;
    unsigned run = multi, hpel = params.hpel;
    for (unsigned y = 0; y < (unsigned)height; y++) {
        uint32_t a = addr;
        if (!(s->cr[VGA_CRTC_MODE] & 1)) {
            unsigned bit = 14 + ((s->cr[VGA_CRTC_MODE] >> 6) & 1);
            a = (a & ~(1u << bit)) | ((y1 & 1) << bit);
        }
        if (!(s->cr[VGA_CRTC_MODE] & 2))
            a = (a & ~0x8000u) | ((y1 & 2) << 14);
        unsigned pan = u.mode == 0 || u.mode == 8 ? (hpel >> 1) & 3 :
                       u.mode == 2 || u.mode == 4 ? hpel & 7 :
                                                    0;
        if (u.mode == 0 &&
            (uint64_t)a + ((unsigned)width >> 3) * 4 < 256u * 1024) {
            a += pan * 4;
            pan = 0;
        }
        rows[y] = (NV2AMetalVGARow){ a, pan };
        if (!run) {
            unsigned mask = (s->cr[VGA_CRTC_MODE] & 3) ^ 3;
            if ((y1 & mask) == mask)
                addr += params.line_offset;
            y1++;
            run = multi;
        } else
            run--;
        if (y == params.line_compare) {
            if (params.hpel_split)
                hpel = 8;
            addr = 0;
        }
    }
    return [self captureVGARows:rows uniforms:&u error:error];
}
- (BOOL)renderWithError:(NSError **)error
{
    return [self completeCaptureWaiting:YES error:error] &&
           [self captureWithError:error] &&
           [self completeCaptureWaiting:YES error:error];
}
- (BOOL)updatePresentationWithError:(NSError **)error
{
    return [self completeCaptureWaiting:NO error:error] &&
           (_pendingRecording || [self captureWithError:error]);
}
- (BOOL)captureWithError:(NSError **)error
{
    if (!_d->vga.get_resolution || !_d->vga.get_params)
        return capture_error(error, @"Missing VGA scanout interfaces");
    int w, h;
    VGADisplayParams params = { .hpel = 8, .line_compare = UINT32_MAX };
    _d->vga.get_resolution(&_d->vga, &w, &h);
    _d->vga.get_params(&_d->vga, &params);
    NV2AMetalCachedSurface *source =
        [_cache surfaceContainingAddress:(uint64_t)_d->pcrtc.start +
                                         params.line_offset];
    if (_diagnostics &&
        (++_diagnosticFrames <= 3 || _diagnosticFrames % 60 == 0)) {
        fprintf(stderr,
                "[Metal4] scanout=%" PRIu64
                " route=%s resolution=%dx%d start=0x%llx line_offset=%u"
                " source_address=0x%llx source_pitch=%u clock_mode=0x%x\n",
                _diagnosticFrames,
                source && source.transfer.config.color ? "pgraph" : "vga",
                w, h, (unsigned long long)_d->pcrtc.start,
                (unsigned)params.line_offset,
                (unsigned long long)source.address,
                source ? (unsigned)source.transfer.config.pitch : 0,
                _d->vga.sr[VGA_SEQ_CLOCK_MODE]);
    }
    if (!source || !source.transfer.config.color) {
        _lastSource = nil;
        return [self renderVGAWithWidth:w height:h params:params error:error];
    }
    unsigned scale = _d->pgraph.surface_scale_factor;
    uint64_t height = h > 0 ? (uint64_t)h : 0;
    if (_d->vga.cr[NV_PRMCIO_INTERLACE_MODE] !=
        NV_PRMCIO_INTERLACE_MODE_DISABLED)
        height *= 2;
    if (w <= 0 || !height || !scale || scale > 16384 ||
        (uint64_t)w * scale > 16384 || height * scale > 16384)
        return capture_error(error, @"Invalid VGA resolution or scanout scale");
    unsigned width = (unsigned)w * scale, out_height = (unsigned)height * scale;
    unsigned line = params.line_offset ?
                        source.transfer.config.pitch / params.line_offset :
                        1;
    if (!line)
        return capture_error(
            error, @"VGA line offset produces zero GL pitch quotient");
    NV2AMetalScanoutUniforms u = { .output_size = { width, out_height },
                                   .line_offset = line,
                                   .source_border = source.scanoutClampToBorder,
                                   .dither = 1 };
    const uint32_t *r = _d->pvideo.regs;
    u.overlay_enable = (r[NV_PVIDEO_BUFFER] & NV_PVIDEO_BUFFER_0_USE) &&
                       r[NV_PVIDEO_SIZE_IN] != UINT32_MAX;
    NV2AMetalTextureShape shape = { 0 };
    NSUInteger address = 0, length = 0;
    if (u.overlay_enable) {
        unsigned ow = GET_MASK(r[NV_PVIDEO_SIZE_OUT], NV_PVIDEO_SIZE_OUT_WIDTH);
        unsigned oh =
            GET_MASK(r[NV_PVIDEO_SIZE_OUT], NV_PVIDEO_SIZE_OUT_HEIGHT);
        unsigned iw = GET_MASK(r[NV_PVIDEO_SIZE_IN], NV_PVIDEO_SIZE_IN_WIDTH);
        unsigned ih = GET_MASK(r[NV_PVIDEO_SIZE_IN], NV_PVIDEO_SIZE_IN_HEIGHT);
        unsigned pitch = GET_MASK(r[NV_PVIDEO_FORMAT], NV_PVIDEO_FORMAT_PITCH);
        unsigned format = GET_MASK(r[NV_PVIDEO_FORMAT], NV_PVIDEO_FORMAT_COLOR);
        if (!ow || !oh || format != NV_PVIDEO_FORMAT_COLOR_LE_CR8YB8CB8YA8)
            return capture_error(
                error, @"Unsupported/empty PVIDEO format or output size");
        float sx = pvideo_scale(r[NV_PVIDEO_DS_DX], ow),
              sy = pvideo_scale(r[NV_PVIDEO_DT_DY], oh);
        if (iw > ow)
            iw = (unsigned)floorf(ow * sx + .5f);
        if (ih > oh)
            ih = (unsigned)floorf(oh * sy + .5f);
        shape = (NV2AMetalTextureShape){
            .format = NV097_SET_TEXTURE_FORMAT_COLOR_LC_IMAGE_CR8YB8CB8YA8,
            .dimension = 2,
            .width = iw,
            .height = ih,
            .depth = 1,
            .levels = 1,
            .pitch = pitch
        };
        if (![_upload sourceLengthForShape:&shape
                             paletteLength:0
                                    length:&length
                                     error:error])
            return NO;
        uint64_t offset = r[NV_PVIDEO_OFFSET], base = r[NV_PVIDEO_BASE];
        if (offset + length > r[NV_PVIDEO_LIMIT] ||
            base + offset > _cache.vram.length ||
            length > _cache.vram.length - base - offset)
            return capture_error(error, @"PVIDEO exceeds LIMIT or VRAM");
        address = (NSUInteger)(base + offset);
        u.overlay_input[0] =
            GET_MASK(r[NV_PVIDEO_POINT_IN], NV_PVIDEO_POINT_IN_S) / 16.f;
        u.overlay_input[1] =
            GET_MASK(r[NV_PVIDEO_POINT_IN], NV_PVIDEO_POINT_IN_T) / 8.f;
        u.overlay_rect[0] =
            GET_MASK(r[NV_PVIDEO_POINT_OUT], NV_PVIDEO_POINT_OUT_X) * scale;
        unsigned oy =
            GET_MASK(r[NV_PVIDEO_POINT_OUT], NV_PVIDEO_POINT_OUT_Y) * scale;
        unsigned sw = ow * scale, sh = oh * scale;
        u.overlay_rect[1] =
            MAX((int64_t)out_height - 1 - ((int64_t)oy + sh), 0);
        u.overlay_rect[2] = sw;
        u.overlay_rect[3] = sh;
        u.overlay_scale[0] = sx;
        u.overlay_scale[1] = sy;
        u.overlay_scale[2] = 1.f / scale;
        u.color_key_enable = !!(r[NV_PVIDEO_FORMAT] & NV_PVIDEO_FORMAT_DISPLAY);
        u.color_key[0] =
            GET_MASK(r[NV_PVIDEO_COLOR_KEY], NV_PVIDEO_COLOR_KEY_RED) / 255.f;
        u.color_key[1] =
            GET_MASK(r[NV_PVIDEO_COLOR_KEY], NV_PVIDEO_COLOR_KEY_GREEN) / 255.f;
        u.color_key[2] =
            GET_MASK(r[NV_PVIDEO_COLOR_KEY], NV_PVIDEO_COLOR_KEY_BLUE) / 255.f;
    }
    uint64_t sourceVersion;
    if (![_cache sourceVersionAtAddress:source.address
                                 length:source.reservationLength
                                version:&sourceVersion
                                  error:error])
        return NO;
    uint64_t overlayVersion = 0;
    if (u.overlay_enable &&
        ![_cache sourceVersionAtAddress:address length:length
                                 version:&overlayVersion error:error])
        return NO;
    /* PVIDEO always decodes one linear YUY2 level. The layout can change
     * while the shader's sampling rectangle and scale stay identical. */
    const uint64_t overlayKey[] = {
        address, length, shape.width, shape.height, shape.pitch, overlayVersion,
    };
    /* Completed targets are immutable. Only metadata such as DAC palette and
     * SCREEN_OFF needs republishing while the GPU source is unchanged. */
    NV2AMetalFramebuffer *frame = self.frame;
    if (frame && source == _lastSource &&
        source.generation == _lastSourceGeneration &&
        sourceVersion == _lastSourceVersion && !source.needsUpload &&
        !memcmp(&u, &_lastUniforms, sizeof(u)) &&
        !memcmp(overlayKey, _lastOverlayKey, sizeof(overlayKey))) {
        BOOL overlayReady = YES;
        if (u.overlay_enable) {
            /* A queued write or a GPU-owned alias still needs the normal
             * ordered read, even if the current version happens to match. */
            NV2AMetalVRAMReadSpan span = { address, length };
            if (![_cache tryIdleCPUReadSpans:&span count:1
                                   completed:&overlayReady error:error])
                return NO;
        }
        if (overlayReady) {
            if (![_cache touchSurface:source
                                frame:_d->pgraph.frame_time
                                error:error])
                return NO;
            [self refreshMetadataForFrame:frame];
            return YES;
        }
    }
    MTLPixelFormat format = source.transfer.nativePixelFormat;
    NSNumber *key = @(format);
    NV2AMetalScanout *pipeline = _pipelines[key];
    if (!pipeline) {
        pipeline =
            [[NV2AMetalScanout alloc] initWithDevice:_cache.commands.device
                                         pixelFormat:format
                                               error:error];
        if (!pipeline)
            return NO;
        _pipelines[key] = pipeline;
    }
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:width
                                                          height:out_height
                                                       mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> target = [_targetPool takeTexture:td
                                            device:_cache.commands.device];
    if (!target)
        return capture_error(error,
                             @"Cannot allocate immutable scanout target");
    if (![self preserveOpenSectionWithError:error])
        return NO;
    NV2AMetalTextureUploadResult *overlay = nil;
    id<MTLTexture> input = nil;
    NV2AMetalSurfaceConfig config = source.transfer.config;
    /* A PVIDEO writeback may require a new queue wait. Establish that
     * dependency before the primary surface opens the capture section. */
    if (u.overlay_enable && ![_cache prepareGPUReadAtAddress:address
                                                      length:length
                                                       error:error])
        goto fail;
    source = [_cache prepareSurfaceAtAddress:source.address
                                      config:&config
                                       frame:_d->pgraph.frame_time
                                       error:error];
    if (!source)
        goto fail;
    if (u.overlay_enable) {
        overlay = [_upload encodeData:_cache.vram
                               offset:address
                              palette:nil
                        paletteOffset:0
                        paletteLength:0
                                shape:&shape
                             commands:_cache.commands
                                error:error];
        if (!overlay)
            goto fail;
    }
    input = [source.transfer textureForCommands:_cache.commands error:error];
    if (!input)
        goto fail;
    if (![pipeline encodeSource:input
                        overlay:overlay.texture
                         target:target
                       uniforms:&u
                       commands:_cache.commands
                          error:error] ||
        ![self submitTexture:target error:error])
        goto fail;
    _lastSource = source;
    _lastSourceGeneration = source.generation;
    _lastSourceVersion = sourceVersion;
    memcpy(_lastOverlayKey, overlayKey, sizeof(overlayKey));
    _lastUniforms = u;
    return YES;
fail:
    [_cache cancel];
    return NO;
}
@end
