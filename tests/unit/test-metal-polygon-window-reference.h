/* Exact source reversal for the polygon window-work gate.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_POLYGON_WINDOW_REFERENCE_H
#define TEST_METAL_POLYGON_WINDOW_REFERENCE_H

static NSString *polygon_window_source(NSString *production, unsigned variant)
{
    assert(variant < 4);
    if (!variant)
        return production;
    NSString *helperStart = @"/* Keep derivative helpers together; every lane "
                            @"rejoins before the existing\n";
    NSRange begin = [production rangeOfString:helperStart];
    assert(begin.location != NSNotFound);
    NSRange after = [production
        rangeOfString:@"static PixelOutput\n"
              options:0
                range:NSMakeRange(NSMaxRange(begin),
                                  production.length - NSMaxRange(begin))];
    assert(after.location != NSNotFound);
    NSRange helper =
        NSMakeRange(begin.location, after.location - begin.location);
    if (variant > 1) {
        NSString *replacement = [NSString
            stringWithFormat:
                @"static bool pixel_skip_window_polygon(bool window_clipped, "
                @"bool needs_helpers)\n{\n    return %@;\n}\n\n",
                variant == 2 ? @"false" : @"true"];
        return [production stringByReplacingCharactersInRange:helper
                                                   withString:replacement];
    }
    NSMutableString *source = [production mutableCopy];
    [source deleteCharactersInRange:helper];
    NSString *windowStart = @"    float2 coordinate = in.position.xy - 0.5f;\n";
    NSRange window = [source rangeOfString:windowStart];
    NSString *windowEnd = @"    bool window_clipped = contained == "
                          @"bool(u.window_clip_exclusive);\n";
    NSRange end = [source rangeOfString:windowEnd];
    assert(window.location != NSNotFound && end.location > window.location);
    NSString *windowLoop =
        [source substringWithRange:NSMakeRange(window.location,
                                               end.location - window.location)];
    [source
        deleteCharactersInRange:NSMakeRange(window.location,
                                            NSMaxRange(end) - window.location)];
    NSString *gate =
        @"        bool needs_helpers = pixel_quad_helpers(\n"
         "            NV2A_COMBINER_SHADER_STAGE_PROGRAM(u.combiner), "
         "u.legacy_spec_const,\n"
         "            u.textures);\n"
         "        if (!pixel_skip_window_polygon(window_clipped, "
         "needs_helpers)) {\n";
    NSRange gateRange = [source rangeOfString:gate];
    NSString *tail = @"        }\n    }\n    if (window_clipped) {\n";
    NSRange tailRange = [source rangeOfString:tail];
    assert(gateRange.location != NSNotFound &&
           tailRange.location > NSMaxRange(gateRange));
    NSString *body =
        [source substringWithRange:NSMakeRange(NSMaxRange(gateRange),
                                               tailRange.location -
                                                   NSMaxRange(gateRange))];
    NSMutableString *dedented = [NSMutableString new];
    for (NSString *line in [body componentsSeparatedByString:@"\n"]) {
        assert(!line.length || [line hasPrefix:@"    "]);
        if (line.length)
            [dedented appendFormat:@"%@\n", [line substringFromIndex:4]];
    }
    NSString *newGate = @"        if (!needs_helpers) {\n";
    NSString *oldGate = @"        if "
                        @"(!pixel_quad_helpers(NV2A_COMBINER_SHADER_STAGE_"
                        @"PROGRAM(u.combiner),\n"
                         "                                u.legacy_spec_const, "
                         "u.textures)) {\n";
    assert([dedented componentsSeparatedByString:newGate].count == 2);
    [dedented replaceOccurrencesOfString:newGate
                              withString:oldGate
                                 options:0
                                   range:NSMakeRange(0, dedented.length)];
    [source replaceCharactersInRange:NSMakeRange(gateRange.location,
                                                 tailRange.location +
                                                     @"        }\n".length -
                                                     gateRange.location)
                          withString:dedented];
    NSString *late = @"    if (window_clipped) {\n";
    assert([source componentsSeparatedByString:late].count == 2);
    NSString *oldLate = [windowLoop
        stringByAppendingString:
            @"    if (contained == bool(u.window_clip_exclusive)) {\n"];
    [source replaceOccurrencesOfString:late
                            withString:oldLate
                               options:0
                                 range:NSMakeRange(0, source.length)];
    /* The complete old source, including unrelated fragments, is restored. */
    assert([source lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 624 ==
           [production lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    return source;
}
#endif
