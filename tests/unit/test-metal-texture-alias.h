/* Shared UI texture-storage validation; no window or xemu instance.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_TEXTURE_ALIAS_H
#define TEST_METAL_TEXTURE_ALIAS_H

#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>

static void texture_alias_cases(id<MTLDevice> device,
                                void (^check)(id<MTLTexture>, id<MTLTexture>,
                                              BOOL))
{
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:8
                                    height:8
                                 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
               MTLTextureUsagePixelFormatView;
    id<MTLTexture> root = [device newTextureWithDescriptor:td];
    id<MTLTexture> other = [device newTextureWithDescriptor:td];
    id<MTLTexture> a = [root newTextureViewWithPixelFormat:td.pixelFormat];
    id<MTLTexture> b = [root newTextureViewWithPixelFormat:td.pixelFormat];
    id<MTLTexture> nested = [a newTextureViewWithPixelFormat:td.pixelFormat];
    assert(root && other && a && b && nested);
    check(root, root, NO);
    check(a, root, NO);
    check(root, a, NO);
    check(a, b, NO);
    check(nested, b, NO);
    check(b, nested, NO);
    check(a, other, YES);
    check(other, b, YES);
    check(other, root, YES);

    NSUInteger row = 8 * 4;
    NSUInteger alignment =
        [device minimumLinearTextureAlignmentForPixelFormat:td.pixelFormat];
    row = (row + alignment - 1) / alignment * alignment;
    NSUInteger span = row * 8;
    id<MTLBuffer> buffer =
        [device newBufferWithLength:span * 2
                            options:MTLResourceStorageModeShared];
    id<MTLBuffer> independent =
        [device newBufferWithLength:span options:MTLResourceStorageModeShared];
    id<MTLTexture> x = [buffer newTextureWithDescriptor:td
                                                 offset:0
                                            bytesPerRow:row];
    id<MTLTexture> y = [buffer newTextureWithDescriptor:td
                                                 offset:0
                                            bytesPerRow:row];
    id<MTLTexture> z = [buffer newTextureWithDescriptor:td
                                                 offset:span
                                            bytesPerRow:row];
    id<MTLTexture> separate = [independent newTextureWithDescriptor:td
                                                             offset:0
                                                        bytesPerRow:row];
    id<MTLTexture> view = [x newTextureViewWithPixelFormat:td.pixelFormat];
    assert(buffer && independent && x && y && z && separate && view);
    check(x, y, NO);
    check(y, x, NO);
    check(view, y, NO);
    check(y, view, NO);
    /* Match the renderer's conservative same-buffer contract, even for
     * disjoint views; callers can copy into a separate resource instead. */
    check(x, z, NO);
    check(z, x, NO);
    check(x, separate, YES);
    check(separate, view, YES);
    check(x, other, YES);
    check(other, view, YES);
    puts("Texture storage aliases: 12 rejections, 7 independent controls PASS");
}
#endif
