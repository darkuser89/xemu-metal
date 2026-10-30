/* Metal texture storage shared by render attachments and sampled views.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_ALIAS_H
#define HW_XBOX_NV2A_PGRAPH_METAL_TEXTURE_ALIAS_H

#import <Metal/Metal.h>

static inline BOOL nv2a_metal_textures_alias(id<MTLTexture> a, id<MTLTexture> b)
{
    if (!a || !b) {
        return NO;
    }
    while (a.parentTexture) {
        a = a.parentTexture;
    }
    while (b.parentTexture) {
        b = b.parentTexture;
    }
    return a == b || (a.buffer && a.buffer == b.buffer);
}

#endif
