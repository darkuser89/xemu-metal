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
@interface NV2AMetalFramebuffer ()
@property(nonatomic, readwrite) id<MTLTexture> texture;
@property(nonatomic, readwrite) NV2AMetalDisplayUniforms displayUniforms;
@property(nonatomic, readwrite) BOOL screenOff;
- (instancetype)initFrame;
@end
@implementation NV2AMetalFramebuffer
- (instancetype)initFrame
{
    return [super init];
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
@implementation NV2AMetalPGRAPHScanout {
    NV2AState *_d;
    NV2AMetalSurfaceCache *_cache;
    NV2AMetalTextureUpload *_upload;
    NV2AMetalVGA *_vga;
    NSMutableDictionary<NSNumber *, NV2AMetalScanout *> *_pipelines;
    BOOL _diagnostics;
    uint64_t _diagnosticFrames;
    NV2AMetalCachedSurface *_lastSource;
    uint64_t _lastSourceGeneration, _lastSourceVersion;
    NV2AMetalScanoutUniforms _lastUniforms;
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
    _vga = [[NV2AMetalVGA alloc] initWithDevice:cache.commands.device
                                          error:error];
    _pipelines = [NSMutableDictionary new];
    return _upload && _vga ? self : nil;
}
- (void)invalidate
{
    _frame = nil;
    _lastSource = nil;
}
- (void)publishTexture:(id<MTLTexture>)texture
{
    NV2AMetalFramebuffer *frame = [[NV2AMetalFramebuffer alloc] initFrame];
    frame.texture = texture;
    NV2AMetalDisplayUniforms display = { .scale = { 1, 1 } };
    for (unsigned i = 0; i < 256; i++)
        display.palette[i] = _d->puserdac.palette[i * 3] |
                             (uint32_t)_d->puserdac.palette[i * 3 + 1] << 8 |
                             (uint32_t)_d->puserdac.palette[i * 3 + 2] << 16;
    frame.displayUniforms = display;
    frame.screenOff = !!(_d->vga.sr[VGA_SEQ_CLOCK_MODE] & VGA_SR01_SCREEN_OFF);
    _frame = frame;
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
        _frame = nil;
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
    NV2AMetalVGARow *rows = g_new0(NV2AMetalVGARow, u.height);
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
    BOOL ok = [_cache submitWithError:error] &&
              [_cache prepareGPUReadAtAddress:0
                                       length:_cache.vram.length
                                        error:error];
    id<MTLTexture> texture = ok ? [_vga encodeData:_cache.vram
                                              rows:rows
                                          uniforms:&u
                                          commands:_cache.commands
                                             error:error] :
                                  nil;
    g_free(rows);
    if (!texture || ![_cache submitWithError:error]) {
        [_cache cancel];
        return NO;
    }
    if (![_cache waitUntilIdleWithError:error])
        return NO;
    [self publishTexture:texture];
    return YES;
}
- (BOOL)renderVGAWithWidth:(int)width
                    height:(int)height
                    params:(VGADisplayParams)params
                     error:(NSError **)error
{
    VGACommonState *s = &_d->vga;
    if (!s->get_bpp || width <= 0 || height <= 0) {
        _frame = nil;
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
    NV2AMetalVGARow *rows = g_new0(NV2AMetalVGARow, height);
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
    BOOL ok = [_cache submitWithError:error] &&
              [_cache prepareGPUReadAtAddress:0
                                       length:(NSUInteger)u.memory_mask + 1
                                        error:error];
    id<MTLTexture> texture = ok ? [_vga encodeData:_cache.vram
                                              rows:rows
                                          uniforms:&u
                                          commands:_cache.commands
                                             error:error] :
                                  nil;
    g_free(rows);
    if (!texture || ![_cache submitWithError:error]) {
        [_cache cancel];
        return NO;
    }
    if (![_cache waitUntilIdleWithError:error])
        return NO;
    [self publishTexture:texture];
    return YES;
}
- (BOOL)renderWithError:(NSError **)error
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
    /* Completed targets are immutable. Only metadata such as DAC palette and
     * SCREEN_OFF needs republishing while the GPU source is unchanged. */
    if (_frame && !u.overlay_enable && source == _lastSource &&
        source.generation == _lastSourceGeneration &&
        sourceVersion == _lastSourceVersion && !source.needsUpload &&
        !memcmp(&u, &_lastUniforms, sizeof(u))) {
        if (![_cache touchSurface:source
                            frame:_d->pgraph.frame_time
                            error:error])
            return NO;
        [self publishTexture:_frame.texture];
        return YES;
    }
    MTLPixelFormat format = source.transfer.texture.pixelFormat;
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
    id<MTLTexture> target =
        [_cache.commands.device newTextureWithDescriptor:td];
    if (!target)
        return capture_error(error,
                             @"Cannot allocate immutable scanout target");
    if (![_cache submitWithError:error])
        return NO;
    NV2AMetalTextureUploadResult *overlay = nil;
    NV2AMetalSurfaceConfig config = source.transfer.config;
    source = [_cache prepareSurfaceAtAddress:source.address
                                      config:&config
                                       frame:_d->pgraph.frame_time
                                       error:error];
    if (!source)
        goto fail;
    if (u.overlay_enable) {
        if (![_cache prepareGPUReadAtAddress:address length:length error:error])
            goto fail;
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
    if (![pipeline encodeSource:source.transfer.texture
                        overlay:overlay.texture
                         target:target
                       uniforms:&u
                       commands:_cache.commands
                          error:error] ||
        ![_cache submitWithError:error])
        goto fail;
    if (![_cache waitUntilIdleWithError:error])
        return NO;
    [self publishTexture:target];
    _lastSource = u.overlay_enable ? nil : source;
    _lastSourceGeneration = source.generation;
    _lastSourceVersion = sourceVersion;
    _lastUniforms = u;
    return YES;
fail:
    [_cache cancel];
    return NO;
}
@end
