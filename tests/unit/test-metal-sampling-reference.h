/* Keep the previous gradient path as a native shader reference.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_SAMPLING_REFERENCE_H
#define TEST_METAL_SAMPLING_REFERENCE_H
static NSString *sampling_force_gradients(NSString *source)
{
    /* Restore the old rolled texture loop and unconditional derivatives;
     * do not make the oracle depend on folding a false helper call. */
    NSString *loop = @"#pragma unroll\n    for (uint i = 0; i < 4; i++)";
    assert([source componentsSeparatedByString:loop].count == 3);
    source = [source
        stringByReplacingOccurrencesOfString:loop
                                  withString:
                                      @"    for (uint i = 0; i < 4; i++)"];
    for (NSString *type in @[ @"float2", @"float3" ]) {
        NSString *block =
            [NSString stringWithFormat:@"    %@ dx(0), dy(0);\n"
                                        "    if (!sample_base_only(s)) {\n"
                                        "        dx = dfdx(c);\n"
                                        "        dy = dfdy(c);\n"
                                        "    }\n",
                                       type];
        assert([source componentsSeparatedByString:block].count ==
               ([type isEqualToString:@"float2"] ? 2u : 3u));
        source = [source
            stringByReplacingOccurrencesOfString:block
                                      withString:
                                          [NSString stringWithFormat:
                                                        @"    %@ dx = dfdx(c), "
                                                        @"dy = dfdy(c);\n",
                                                        type]];
    }
    NSString *signature = @"static bool sample_base_only(";
    assert([source componentsSeparatedByString:signature].count == 2);
    NSRange start = [source rangeOfString:signature];
    NSRange body =
        [source rangeOfString:@"{"
                      options:0
                        range:NSMakeRange(start.location,
                                          source.length - start.location)];
    NSRange end =
        [source rangeOfString:@"\n}"
                      options:0
                        range:NSMakeRange(NSMaxRange(body),
                                          source.length - NSMaxRange(body))];
    assert(body.location != NSNotFound && end.location != NSNotFound);
    return [source
        stringByReplacingCharactersInRange:NSMakeRange(NSMaxRange(body),
                                                       end.location -
                                                           NSMaxRange(body))
                                withString:
                                    @"\n    (void)s;\n    return false;"];
}
#endif
