/*
 * Offscreen native Metal 4 attribute-fetch tests
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only
 */

#import "hw/xbox/nv2a/pgraph/metal/vertex-fetch.h"
#import "hw/xbox/nv2a/pgraph/metal/vertex-fixed.h"
#import "hw/xbox/nv2a/pgraph/metal/vertex-program.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void require(BOOL success, NSError *error)
{
    if (!success) {
        const char *message = error.localizedDescription.UTF8String;
        fprintf(stderr, "Vertex fetch failed: %s\n",
                message ? message : "unknown error");
        abort();
    }
}

static void check_float(float value, float expected)
{
    if (!isfinite(value) ||
        fabsf(value - expected) > 0.000002f * fmaxf(1, fabsf(expected))) {
        fprintf(stderr, "Fetch value: got %g, expected %g\n", value, expected);
        abort();
    }
}

/* Fixed raw bits from original envytools pgraph_idx.c at
 * f102b82381f3f11cee113d16374c87091db039d9. The hardware model directly
 * covers immediate values; applying IDX conversion to arrays is an inference.
 * Keep this fixture independent of the Metal normalization algorithm. */
static const uint32_t kelvin_ubyte[256] = {
    0x00000000u, 0x3b808080u, 0x3c008080u, 0x3c40c0c0u, 0x3c808080u,
    0x3ca0a0a0u, 0x3cc0c0c0u, 0x3ce0e0e0u, 0x3d008080u, 0x3d109090u,
    0x3d20a0a0u, 0x3d30b0b0u, 0x3d40c0c0u, 0x3d50d0d0u, 0x3d60e0e0u,
    0x3d70f0f0u, 0x3d808080u, 0x3d888888u, 0x3d909090u, 0x3d989898u,
    0x3da0a0a0u, 0x3da8a8a8u, 0x3db0b0b0u, 0x3db8b8b8u, 0x3dc0c0c0u,
    0x3dc8c8c8u, 0x3dd0d0d0u, 0x3dd8d8d8u, 0x3de0e0e0u, 0x3de8e8e8u,
    0x3df0f0f0u, 0x3df8f8f8u, 0x3e008080u, 0x3e048484u, 0x3e088888u,
    0x3e0c8c8cu, 0x3e109090u, 0x3e149494u, 0x3e189898u, 0x3e1c9c9cu,
    0x3e20a0a0u, 0x3e24a4a4u, 0x3e28a8a8u, 0x3e2cacacu, 0x3e30b0b0u,
    0x3e34b4b4u, 0x3e38b8b8u, 0x3e3cbcbcu, 0x3e40c0c0u, 0x3e44c4c4u,
    0x3e48c8c8u, 0x3e4cccccu, 0x3e50d0d0u, 0x3e54d4d4u, 0x3e58d8d8u,
    0x3e5cdcdcu, 0x3e60e0e0u, 0x3e64e4e4u, 0x3e68e8e8u, 0x3e6cececu,
    0x3e70f0f0u, 0x3e74f4f4u, 0x3e78f8f8u, 0x3e7cfcfcu, 0x3e808080u,
    0x3e828282u, 0x3e848484u, 0x3e868686u, 0x3e888888u, 0x3e8a8a8au,
    0x3e8c8c8cu, 0x3e8e8e8eu, 0x3e909090u, 0x3e929292u, 0x3e949494u,
    0x3e969696u, 0x3e989898u, 0x3e9a9a9au, 0x3e9c9c9cu, 0x3e9e9e9eu,
    0x3ea0a0a0u, 0x3ea2a2a2u, 0x3ea4a4a4u, 0x3ea6a6a6u, 0x3ea8a8a8u,
    0x3eaaaaaau, 0x3eacacacu, 0x3eaeaeaeu, 0x3eb0b0b0u, 0x3eb2b2b2u,
    0x3eb4b4b4u, 0x3eb6b6b6u, 0x3eb8b8b8u, 0x3ebababau, 0x3ebcbcbcu,
    0x3ebebebeu, 0x3ec0c0c0u, 0x3ec2c2c2u, 0x3ec4c4c4u, 0x3ec6c6c6u,
    0x3ec8c8c8u, 0x3ecacacau, 0x3eccccccu, 0x3ecececeu, 0x3ed0d0d0u,
    0x3ed2d2d2u, 0x3ed4d4d4u, 0x3ed6d6d6u, 0x3ed8d8d8u, 0x3edadadau,
    0x3edcdcdcu, 0x3edededeu, 0x3ee0e0e0u, 0x3ee2e2e2u, 0x3ee4e4e4u,
    0x3ee6e6e6u, 0x3ee8e8e8u, 0x3eeaeaeau, 0x3eecececu, 0x3eeeeeeeu,
    0x3ef0f0f0u, 0x3ef2f2f2u, 0x3ef4f4f4u, 0x3ef6f6f6u, 0x3ef8f8f8u,
    0x3efafafau, 0x3efcfcfcu, 0x3efefefeu, 0x3f008080u, 0x3f018181u,
    0x3f028282u, 0x3f038383u, 0x3f048484u, 0x3f058585u, 0x3f068686u,
    0x3f078787u, 0x3f088888u, 0x3f098989u, 0x3f0a8a8au, 0x3f0b8b8bu,
    0x3f0c8c8cu, 0x3f0d8d8du, 0x3f0e8e8eu, 0x3f0f8f8fu, 0x3f109090u,
    0x3f119191u, 0x3f129292u, 0x3f139393u, 0x3f149494u, 0x3f159595u,
    0x3f169696u, 0x3f179797u, 0x3f189898u, 0x3f199999u, 0x3f1a9a9au,
    0x3f1b9b9bu, 0x3f1c9c9cu, 0x3f1d9d9du, 0x3f1e9e9eu, 0x3f1f9f9fu,
    0x3f20a0a0u, 0x3f21a1a1u, 0x3f22a2a2u, 0x3f23a3a3u, 0x3f24a4a4u,
    0x3f25a5a5u, 0x3f26a6a6u, 0x3f27a7a7u, 0x3f28a8a8u, 0x3f29a9a9u,
    0x3f2aaaaau, 0x3f2bababu, 0x3f2cacacu, 0x3f2dadadu, 0x3f2eaeaeu,
    0x3f2fafafu, 0x3f30b0b0u, 0x3f31b1b1u, 0x3f32b2b2u, 0x3f33b3b3u,
    0x3f34b4b4u, 0x3f35b5b5u, 0x3f36b6b6u, 0x3f37b7b7u, 0x3f38b8b8u,
    0x3f39b9b9u, 0x3f3ababau, 0x3f3bbbbbu, 0x3f3cbcbcu, 0x3f3dbdbdu,
    0x3f3ebebeu, 0x3f3fbfbfu, 0x3f40c0c0u, 0x3f41c1c1u, 0x3f42c2c2u,
    0x3f43c3c3u, 0x3f44c4c4u, 0x3f45c5c5u, 0x3f46c6c6u, 0x3f47c7c7u,
    0x3f48c8c8u, 0x3f49c9c9u, 0x3f4acacau, 0x3f4bcbcbu, 0x3f4cccccu,
    0x3f4dcdcdu, 0x3f4ececeu, 0x3f4fcfcfu, 0x3f50d0d0u, 0x3f51d1d1u,
    0x3f52d2d2u, 0x3f53d3d3u, 0x3f54d4d4u, 0x3f55d5d5u, 0x3f56d6d6u,
    0x3f57d7d7u, 0x3f58d8d8u, 0x3f59d9d9u, 0x3f5adadau, 0x3f5bdbdbu,
    0x3f5cdcdcu, 0x3f5dddddu, 0x3f5ededeu, 0x3f5fdfdfu, 0x3f60e0e0u,
    0x3f61e1e1u, 0x3f62e2e2u, 0x3f63e3e3u, 0x3f64e4e4u, 0x3f65e5e5u,
    0x3f66e6e6u, 0x3f67e7e7u, 0x3f68e8e8u, 0x3f69e9e9u, 0x3f6aeaeau,
    0x3f6bebebu, 0x3f6cececu, 0x3f6dededu, 0x3f6eeeeeu, 0x3f6fefefu,
    0x3f70f0f0u, 0x3f71f1f1u, 0x3f72f2f2u, 0x3f73f3f3u, 0x3f74f4f4u,
    0x3f75f5f5u, 0x3f76f6f6u, 0x3f77f7f7u, 0x3f78f8f8u, 0x3f79f9f9u,
    0x3f7afafau, 0x3f7bfbfbu, 0x3f7cfcfcu, 0x3f7dfdfdu, 0x3f7efefeu,
    0x3f800000u,
};

static void check_bits(float value, uint32_t expected)
{
    uint32_t actual;
    memcpy(&actual, &value, sizeof(actual));
    if (actual != expected) {
        fprintf(stderr, "IDX raw bits: got %08x, expected %08x\n", actual,
                expected);
        abort();
    }
}

static id<MTLBuffer> buffer(NV2AMetalCommands *commands, const void *data,
                            NSUInteger length)
{
    id<MTLBuffer> b =
        [commands.device newBufferWithBytes:data
                                     length:length
                                    options:MTLResourceStorageModeShared];
    assert(b);
    return b;
}

static void defaults(NV2AMetalAttributeSource sources[16])
{
    memset(sources, 0, 16 * sizeof(*sources));
    for (unsigned i = 0; i < 16; i++) {
        for (unsigned k = 0; k < 4; k++) {
            sources[i].inline_value[k] = 10 * i + k + .25f;
        }
    }
}

static void begin(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
}

static void finish(NV2AMetalCommands *commands)
{
    NSError *error = nil;
    require([commands submitWithError:&error], error);
    require([commands waitUntilIdleWithError:&error], error);
}

static NV2AMetalFetchResult *
encode(NV2AMetalVertexFetch *fetch, NV2AMetalCommands *commands,
       NV2AMetalAttributeSource sources[16], NSUInteger count, unsigned first,
       id<MTLBuffer> indices, NSUInteger offset, unsigned indexSize)
{
    NSError *error = nil;
    NV2AMetalFetchResult *r = [fetch encodeSources:sources
                                             count:count
                                       firstVertex:first
                                           indices:indices
                                       indexOffset:offset
                                         indexSize:indexSize
                                          commands:commands
                                             error:&error];
    require(r != nil, error);
    return r;
}

static const NV2AMetalProgramInput *values(NV2AMetalFetchResult *r)
{
    const unsigned *fault = r.faults.contents;
    for (NSUInteger i = 0; i < r.vertexCount; i++) {
        assert(fault[i] == 0);
    }
    assert(r.faultSummaryOffset ==
           (r.vertexCount + r.hasCurrent) * sizeof(uint32_t));
    assert(r.faults.length == r.faultSummaryOffset + sizeof(uint32_t));
    assert(!*(const uint32_t *)((const uint8_t *)r.faults.contents +
                                r.faultSummaryOffset));
    return r.attributes.contents;
}

static NV2AMetalFetchResult *run(NV2AMetalVertexFetch *fetch,
                                 NV2AMetalCommands *commands,
                                 NV2AMetalAttributeSource sources[16],
                                 NSUInteger count, unsigned first)
{
    begin(commands);
    NV2AMetalFetchResult *r =
        encode(fetch, commands, sources, count, first, nil, 0, 0);
    finish(commands);
    return r;
}

static void put16(unsigned char *p, unsigned value)
{
    p[0] = value;
    p[1] = value >> 8;
}

static void put32(unsigned char *p, unsigned value)
{
    put16(p, value);
    put16(p + 2, value >> 16);
}

static void kelvin_normalization(NV2AMetalVertexFetch *fetch,
                                 NV2AMetalCommands *commands)
{
    static const struct {
        uint16_t code;
        uint32_t bits;
    } cases[] = {
        { 0x0000, 0x37800080u }, { 0x0001, 0x384000c0u },
        { 0x0002, 0x38a000a0u }, { 0x0003, 0x38e000e0u },
        { 0x0004, 0x39100090u }, { 0x0005, 0x393000b0u },
        { 0x0006, 0x395000d0u }, { 0x0007, 0x397000f0u },
        { 0x0008, 0x39880088u }, { 0x0009, 0x39980098u },
        { 0x000a, 0x39a800a8u }, { 0x000e, 0x39e800e8u },
        { 0x000f, 0x39f800f8u }, { 0x0010, 0x3a040084u },
        { 0x0011, 0x3a0c008cu }, { 0x0012, 0x3a140094u },
        { 0x001e, 0x3a7400f4u }, { 0x001f, 0x3a7c00fcu },
        { 0x0020, 0x3a820082u }, { 0x0021, 0x3a860086u },
        { 0x0022, 0x3a8a008au }, { 0x003e, 0x3afa00fau },
        { 0x003f, 0x3afe00feu }, { 0x0040, 0x3b010081u },
        { 0x0041, 0x3b030083u }, { 0x0042, 0x3b050085u },
        { 0x007e, 0x3b7d00fdu }, { 0x007f, 0x3b7f00ffu },
        { 0x0080, 0x3b808080u }, { 0x0081, 0x3b818081u },
        { 0x0082, 0x3b828082u }, { 0x00fe, 0x3bfe80feu },
        { 0x00ff, 0x3bff80ffu }, { 0x0100, 0x3c004080u },
        { 0x0101, 0x3c00c080u }, { 0x0102, 0x3c014081u },
        { 0x01fe, 0x3c7f40ffu }, { 0x01ff, 0x3c7fc0ffu },
        { 0x0200, 0x3c802080u }, { 0x0201, 0x3c806080u },
        { 0x0202, 0x3c80a080u }, { 0x03fe, 0x3cffa0ffu },
        { 0x03ff, 0x3cffe0ffu }, { 0x0400, 0x3d001080u },
        { 0x0401, 0x3d003080u }, { 0x0402, 0x3d005080u },
        { 0x07fe, 0x3d7fd0ffu }, { 0x07ff, 0x3d7ff0ffu },
        { 0x0800, 0x3d800880u }, { 0x0801, 0x3d801880u },
        { 0x0802, 0x3d802880u }, { 0x0ffe, 0x3dffe8ffu },
        { 0x0fff, 0x3dfff8ffu }, { 0x1000, 0x3e000480u },
        { 0x1001, 0x3e000c80u }, { 0x1002, 0x3e001480u },
        { 0x1ffe, 0x3e7ff4ffu }, { 0x1fff, 0x3e7ffcffu },
        { 0x2000, 0x3e800280u }, { 0x2001, 0x3e800680u },
        { 0x2002, 0x3e800a80u }, { 0x3ffe, 0x3efffaffu },
        { 0x3fff, 0x3efffeffu }, { 0x4000, 0x3f000180u },
        { 0x4001, 0x3f000380u }, { 0x4002, 0x3f000580u },
        { 0x7ffe, 0x3f7ffdffu }, { 0x7fff, 0x3f800000u },
        { 0x8000, 0xbf800000u }, { 0x8001, 0xbf7ffdffu },
        { 0xbffe, 0xbf000380u }, { 0xbfff, 0xbf000180u },
        { 0xc000, 0xbefffeffu }, { 0xc001, 0xbefffaffu },
        { 0xc002, 0xbefff6ffu }, { 0xdffe, 0xbe800680u },
        { 0xdfff, 0xbe800280u }, { 0xe000, 0xbe7ffcffu },
        { 0xe001, 0xbe7ff4ffu }, { 0xe002, 0xbe7fecffu },
        { 0xeffe, 0xbe000c80u }, { 0xefff, 0xbe000480u },
        { 0xf000, 0xbdfff8ffu }, { 0xf001, 0xbdffe8ffu },
        { 0xf002, 0xbdffd8ffu }, { 0xf7fe, 0xbd801880u },
        { 0xf7ff, 0xbd800880u }, { 0xf800, 0xbd7ff0ffu },
        { 0xf801, 0xbd7fd0ffu }, { 0xf802, 0xbd7fb0ffu },
        { 0xfbfe, 0xbd003080u }, { 0xfbff, 0xbd001080u },
        { 0xfc00, 0xbcffe0ffu }, { 0xfc01, 0xbcffa0ffu },
        { 0xfc02, 0xbcff60ffu }, { 0xfdfe, 0xbc806080u },
        { 0xfdff, 0xbc802080u }, { 0xfe00, 0xbc7fc0ffu },
        { 0xfe01, 0xbc7f40ffu }, { 0xfe02, 0xbc7ec0feu },
        { 0xfefe, 0xbc00c080u }, { 0xfeff, 0xbc004080u },
        { 0xff00, 0xbbff80ffu }, { 0xff01, 0xbbfe80feu },
        { 0xff02, 0xbbfd80fdu }, { 0xff7e, 0xbb818081u },
        { 0xff7f, 0xbb808080u }, { 0xff80, 0xbb7f00ffu },
        { 0xff81, 0xbb7d00fdu }, { 0xff82, 0xbb7b00fbu },
        { 0xffbe, 0xbb030083u }, { 0xffbf, 0xbb010081u },
        { 0xffc0, 0xbafe00feu }, { 0xffc1, 0xbafa00fau },
        { 0xffc2, 0xbaf600f6u }, { 0xffde, 0xba860086u },
        { 0xffdf, 0xba820082u }, { 0xffe0, 0xba7c00fcu },
        { 0xffe1, 0xba7400f4u }, { 0xffe2, 0xba6c00ecu },
        { 0xffee, 0xba0c008cu }, { 0xffef, 0xba040084u },
        { 0xfff0, 0xb9f800f8u }, { 0xfff1, 0xb9e800e8u },
        { 0xfff2, 0xb9d800d8u }, { 0xfff6, 0xb9980098u },
        { 0xfff7, 0xb9880088u }, { 0xfff8, 0xb97000f0u },
        { 0xfff9, 0xb95000d0u }, { 0xfffa, 0xb93000b0u },
        { 0xfffb, 0xb9100090u }, { 0xfffc, 0xb8e000e0u },
        { 0xfffd, 0xb8a000a0u }, { 0xfffe, 0xb84000c0u },
        { 0xffff, 0xb7800080u },
    };
    enum { Count = sizeof(cases) / sizeof(cases[0]) };
    unsigned char data[1 + Count * 9 - 1] = { 0 };
    unsigned char indexBytes[1 + Count * 2] = { 0 };
    for (unsigned i = 0; i < Count; i++) {
        for (unsigned k = 0; k < 4; k++) {
            put16(data + 1 + 9 * i + 2 * k, cases[(i + 17 * k) % Count].code);
        }
        put16(indexBytes + 1 + 2 * i, Count - 1 - i);
    }
    id<MTLBuffer> bytes = buffer(commands, data, sizeof(data));
    id<MTLBuffer> indices = buffer(commands, indexBytes, sizeof(indexBytes));
    unsigned channels = 0;
    for (unsigned path = 0; path < 3; path++) {
        NV2AMetalAttributeSource sources[16];
        defaults(sources);
        for (unsigned a = 0; a < 16; a++) {
            sources[a].buffer = bytes;
            sources[a].offset = 1;
            sources[a].stride = path == 2 ? 0 : 9;
            sources[a].count = a % 4 + 1;
            sources[a].format =
                a < 8 ? NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1 :
                        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K;
        }
        NV2AMetalAttributeSource before[16];
        memcpy(before, sources, sizeof(before));
        begin(commands);
        NV2AMetalFetchResult *result = encode(
            fetch, commands, sources, Count,
            path == 2 ? UINT32_MAX - Count + 1 : 0, path == 1 ? indices : nil,
            path == 1 ? 1 : 0, path == 1 ? 2 : 0);
        finish(commands);
        const NV2AMetalProgramInput *out = values(result);
        for (unsigned i = 0; i < Count; i++) {
            unsigned vertex = path == 2 ? 0 : path == 1 ? Count - 1 - i : i;
            for (unsigned a = 0; a < 16; a++) {
                for (unsigned k = 0; k < 4; k++) {
                    unsigned sample = (vertex + 17 * k) % Count;
                    uint32_t expected = k == 3 ? 0x3f800000u : 0;
                    if (k < sources[a].count) {
                        if (a < 8) {
                            expected = cases[sample].bits;
                        } else {
                            int value = cases[sample].code;
                            float raw = value < 32768 ? value : value - 65536;
                            memcpy(&expected, &raw, sizeof(expected));
                        }
                    }
                    check_bits(out[i].attributes[a][k], expected);
                    channels++;
                }
            }
        }
        assert(memcmp(bytes.contents, data, sizeof(data)) == 0);
        assert(memcmp(indices.contents, indexBytes, sizeof(indexBytes)) == 0);
        assert(memcmp(before, sources, sizeof(before)) == 0);
    }
    printf("Metal4 Kelvin IDX: %u fixed short patterns/%u raw channels, "
           "linear/indexed/constant PASS\n",
           Count, channels);
}


/* Compare the fused Current record with the independent stride-zero API.
 * Raw bytes include asymmetric D3D colors and CMP negative endpoints. */
static void fused_current_tests(NV2AMetalVertexFetch *fetch,
                                NV2AMetalCommands *commands)
{
    const unsigned formats[] = { NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
                                 NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP };
    unsigned cases = 0;
    NSError *error = nil;
    uint8_t raw[160];
    for (unsigned i = 0; i < sizeof(raw); i++)
        raw[i] = (i * 37 + 17) & 255;
    uint32_t endpoint = 0x80000400u;
    memcpy(raw + 1, &endpoint, 4);
    id<MTLBuffer> data = buffer(commands, raw, sizeof(raw));
    uint32_t indices32[] = { 4, 1, 3, 0 };
    uint16_t indices16[] = { 4, 1, 3, 0 };
    id<MTLBuffer> indexBuffers[] = {
        nil, buffer(commands, indices16, sizeof(indices16)),
        buffer(commands, indices32, sizeof(indices32))
    };
    for (unsigned fi = 0; fi < sizeof(formats) / sizeof(*formats); fi++) {
        unsigned format = formats[fi];
        for (unsigned components = 1; components <= 4; components++) {
            if (!nv2a_metal_attribute_size(format, components))
                continue;
            for (unsigned constant = 0; constant < 2; constant++) {
                for (unsigned mode = 0; mode < 3; mode++) {
                    NV2AMetalAttributeSource sources[16];
                    defaults(sources);
                    sources[3].buffer = data;
                    sources[3].offset = 1;
                    sources[3].byteLength = 159;
                    sources[3].count = components;
                    sources[3].format = format;
                    sources[3].stride = constant ? 0 : 19;
                    unsigned ordinal = mode == 2 ? 3 : 1;
                    unsigned vertex = mode ? indices32[ordinal] : ordinal + 1;
                    require([commands beginWithError:&error] != nil, error);
                    NV2AMetalFetchResult *fused =
                        [fetch encodeSources:sources
                                       count:4
                                 firstVertex:mode ? 0 : 1
                                     indices:indexBuffers[mode]
                                 indexOffset:0
                                   indexSize:mode == 0 ? 0 :
                                             mode == 1 ? 2 :
                                                         4
                               currentVertex:ordinal
                                    commands:commands
                                       error:&error];
                    require(fused != nil, error);
                    assert(fused.hasCurrent && fused.vertexCount == 4);
                    assert(fused.attributes.length ==
                           5 * sizeof(NV2AMetalProgramInput));
                    assert(fused.faultSummaryOffset == 5 * sizeof(uint32_t));
                    assert(fused.faults.length == 6 * sizeof(uint32_t));
                    sources[3].offset += vertex * sources[3].stride;
                    sources[3].byteLength -= vertex * sources[3].stride;
                    sources[3].stride = 0;
                    NV2AMetalFetchResult *reference =
                        encode(fetch, commands, sources, 1, 0, nil, 0, 0);
                    assert(!reference.hasCurrent);
                    require([commands submitWithError:&error], error);
                    require([commands waitUntilIdleWithError:&error], error);
                    const NV2AMetalProgramInput *out =
                        fused.attributes.contents;
                    assert(!memcmp(out + 4, reference.attributes.contents,
                                   sizeof(*out)));
                    for (unsigned i = 0; i < 5; i++)
                        assert(!((uint32_t *)fused.faults.contents)[i]);
                    cases++;
                }
            }
        }
    }
    /* The selected index may fault; Current must neither read outside DMA
     * nor hide the normal fault, including index+first overflow. */
    for (unsigned overflow = 0; overflow < 2; overflow++) {
        NV2AMetalAttributeSource sources[16];
        defaults(sources);
        sources[0] = (NV2AMetalAttributeSource){
            .buffer = data,
            .byteLength = 16,
            .count = 4,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
            .stride = 16
        };
        uint32_t index = overflow ? UINT32_MAX : 1;
        id<MTLBuffer> ib = buffer(commands, &index, 4);
        require([commands beginWithError:&error] != nil, error);
        NV2AMetalFetchResult *result = [fetch encodeSources:sources
                                                      count:1
                                                firstVertex:overflow
                                                    indices:ib
                                                indexOffset:0
                                                  indexSize:4
                                              currentVertex:0
                                                   commands:commands
                                                      error:&error];
        require(result != nil, error);
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        uint32_t *faults = result.faults.contents;
        assert(faults[0] == (overflow ? UINT32_MAX : 1) &&
               faults[1] == faults[0]);
    }
    NV2AMetalAttributeSource sources[16];
    defaults(sources);
    require([commands beginWithError:&error] != nil, error);
    assert(![fetch encodeSources:sources
                           count:1
                     firstVertex:0
                         indices:nil
                     indexOffset:0
                       indexSize:0
                   currentVertex:1
                        commands:commands
                           error:&error]);
    assert(![fetch encodeSources:sources
                           count:0
                     firstVertex:0
                         indices:nil
                     indexOffset:0
                       indexSize:0
                   currentVertex:0
                        commands:commands
                           error:&error]);
    [commands cancel];
    printf("Metal4 fused Current: %u exact 256-byte comparisons, 2 GPU faults, "
           "2 invalid ordinals PASS\n",
           cases);
}

static uint32_t expected_fetch_fault(uint32_t index, unsigned first)
{
    uint64_t vertex = (uint64_t)index + first;
    if (vertex > UINT32_MAX)
        return UINT32_MAX;
    return (vertex > 0 ? 1u : 0) | (vertex > 1 ? 1u << 7 : 0) |
           (vertex > 2 ? 1u << 15 : 0);
}

static void fault_summary_tests(NV2AMetalVertexFetch *fetch,
                                NV2AMetalCommands *commands)
{
    const unsigned lengths[] = { 1, 2, 31, 32, 33, 255, 256, 257, 4097, 65537 };
    unsigned cases = 0;
    uint64_t words = 0;
    NSError *error = nil;
    uint8_t bytes[49] = { 0 };
    id<MTLBuffer> source = buffer(commands, bytes, sizeof(bytes));
    for (unsigned l = 0; l < sizeof(lengths) / sizeof(*lengths); l++) {
        unsigned count = lengths[l];
        for (unsigned mode = 0; mode < 6; mode++) {
            for (unsigned current = 0; current < 2; current++) {
                @autoreleasepool {
                    NV2AMetalAttributeSource sources[16];
                    defaults(sources);
                    const unsigned attributes[] = { 0, 7, 15 };
                    for (unsigned i = 0; i < 3; i++) {
                        sources[attributes[i]] = (NV2AMetalAttributeSource){
                            .buffer = source,
                            .offset = 1,
                            .byteLength = 16 * (i + 1),
                            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                            .count = 4,
                            .stride = 16
                        };
                    }
                    uint32_t *indices = calloc(count, sizeof(*indices));
                    assert(indices);
                    if (mode >= 1 && mode <= 3)
                        indices[mode == 1 ? 0 :
                                mode == 2 ? count - 1 :
                                            count / 2] = 3;
                    else if (mode == 4)
                        for (unsigned i = 0; i < count; i++)
                            indices[i] = i % 4;
                    else if (mode == 5)
                        for (unsigned i = 0; i < count; i++)
                            indices[i] = i & 1 ? UINT32_MAX : 0;
                    unsigned first = mode == 5 ? 1 : 0;
                    uint32_t expected = 0;
                    for (unsigned i = 0; i < count; i++)
                        expected |= expected_fetch_fault(indices[i], first);
                    id<MTLBuffer> index =
                        buffer(commands, indices, count * sizeof(*indices));
                    require([commands beginWithError:&error] != nil, error);
                    NV2AMetalFetchResult *result =
                        [fetch encodeSources:sources
                                       count:count
                                 firstVertex:first
                                     indices:index
                                 indexOffset:0
                                   indexSize:4
                               currentVertex:current ? count / 2 : NSNotFound
                                    commands:commands
                                       error:&error];
                    require(result != nil, error);
                    assert(result.faultSummaryOffset ==
                           (count + current) * sizeof(uint32_t));
                    assert(result.faults.length ==
                           result.faultSummaryOffset + sizeof(uint32_t));
                    require([commands submitWithError:&error], error);
                    require([commands waitUntilIdleWithError:&error], error);
                    const uint32_t *fault = result.faults.contents;
                    for (unsigned i = 0; i < count; i++)
                        assert(fault[i] ==
                               expected_fetch_fault(indices[i], first));
                    if (current)
                        assert(fault[count] ==
                               expected_fetch_fault(indices[count / 2], first));
                    assert(fault[count + current] == expected);
                    free(indices);
                    words += count;
                    cases++;
                }
            }
        }
    }
    /* Both dispatches use the same argument table in one recording, with
     * different summary offsets and opposite valid/faulted results. */
    for (unsigned order = 0; order < 2; order++) {
        NV2AMetalAttributeSource sources[16];
        defaults(sources);
        sources[0] = (NV2AMetalAttributeSource){
            .buffer = source,
            .offset = 1,
            .byteLength = 16,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
            .count = 4,
            .stride = 16
        };
        NSMutableArray<NV2AMetalFetchResult *> *results = [NSMutableArray new];
        require([commands beginWithError:&error] != nil, error);
        for (unsigned i = 0; i < 2; i++) {
            uint32_t indices[33] = { 0 };
            indices[17] = i == order ? 3 : 0;
            id<MTLBuffer> index = buffer(commands, indices, sizeof(indices));
            NV2AMetalFetchResult *result =
                [fetch encodeSources:sources
                               count:33
                         firstVertex:0
                             indices:index
                         indexOffset:0
                           indexSize:4
                       currentVertex:i ? NSNotFound : 17
                            commands:commands
                               error:&error];
            require(result != nil, error);
            [results addObject:result];
        }
        require([commands submitWithError:&error], error);
        require([commands waitUntilIdleWithError:&error], error);
        for (unsigned i = 0; i < 2; i++) {
            NV2AMetalFetchResult *result = results[i];
            const uint32_t *fault = result.faults.contents;
            for (unsigned v = 0; v < 33; v++)
                assert(fault[v] == (v == 17 && i == order ? 1u : 0));
            if (!i)
                assert(fault[33] == (i == order ? 1u : 0));
            assert(*(const uint32_t *)((const uint8_t *)fault +
                                       result.faultSummaryOffset) ==
                   (i == order ? 1u : 0));
            words += 33;
            cases++;
        }
    }
    printf("Metal4 fetch fault summary: %u cases, %llu exact vertex words; "
           "empty/sparse/dense masks, overflow, unaligned DMA, Current and "
           "same-recording isolation PASS\n",
           cases, (unsigned long long)words);
}

#include "test-metal-fetch-suffix.h"
int main(int argc, char **argv)
{
    bool summaryOnly = argc == 2 && !strcmp(argv[1], "--fault-summary");
    bool suffixOnly = argc == 2 && !strcmp(argv[1], "--suffix");
    assert(argc == 1 || summaryOnly || suffixOnly);
    @autoreleasepool {
        NSError *error = nil;
        NV2AMetalCommands *commands =
            [[NV2AMetalCommands alloc] initWithError:&error];
        require(commands != nil, error);
        NV2AMetalVertexFetch *fetch =
            [[NV2AMetalVertexFetch alloc] initWithDevice:commands.device
                                                   error:&error];
        require(fetch != nil, error);
        if (suffixOnly) {
            fetch_suffix_tests(fetch, commands);
            return 0;
        }
        fault_summary_tests(fetch, commands);
        if (summaryOnly)
            return 0;
        fused_current_tests(fetch, commands);
        fetch_suffix_tests(fetch, commands);
        kelvin_normalization(fetch, commands);
        NV2AMetalAttributeSource sources[16];
        defaults(sources);

        /* Disabled attributes retain all four inline components, including W.
         * No buffer, format or offset is required for a disabled binding. */
        sources[15].format = UINT32_MAX;
        sources[15].offset = NSUIntegerMax;
        NV2AMetalFetchResult *r = run(fetch, commands, sources, 3, 100);
        const NV2AMetalProgramInput *out = values(r);
        for (unsigned v = 0; v < 3; v++) {
            for (unsigned a = 0; a < 16; a++) {
                for (unsigned k = 0; k < 4; k++) {
                    check_float(out[v].attributes[a][k],
                                sources[a].inline_value[k]);
                }
            }
        }

        /* All UB values, component counts, D3D BGRA and interleaving. The last
         * element ends exactly at the buffer boundary; offsets are unaligned.
         */
        unsigned char bytes[1 + 256 * 7 - 3] = { 0 };
        for (unsigned i = 0; i < 256; i++) {
            for (unsigned k = 0; k < 4; k++) {
                bytes[1 + 7 * i + k] = (i + 31 * k) & 255;
            }
        }
        id<MTLBuffer> ub = buffer(commands, bytes, sizeof(bytes));
        defaults(sources);
        for (unsigned a = 0; a < 16; a++) {
            sources[a].buffer = ub;
            sources[a].offset = 1;
            sources[a].stride = 7;
            sources[a].count = a % 4 + 1;
            sources[a].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL;
        }
        sources[15].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D;
        r = run(fetch, commands, sources, 256, 0);
        out = values(r);
        for (unsigned i = 0; i < 256; i++) {
            for (unsigned a = 0; a < 16; a++) {
                for (unsigned k = 0; k < 4; k++) {
                    unsigned component =
                        a == 15 && k != 1 && k != 3 ? 2 - k : k;
                    uint32_t expected =
                        k < sources[a].count ?
                            kelvin_ubyte[(i + 31 * component) & 255] :
                        k == 3 ? 0x3f800000u :
                                 0;
                    check_bits(out[i].attributes[a][k], expected);
                }
            }
        }

        /* GL1.3 table2.6 signed normalization: (2*c+1)/(2^16-1).
         * This numerical check is supplemented by independent raw IDX fixtures.
         * Every signed 16-bit input for both normalized and unnormalized
         * formats, including -32768. Padded strides avoid host alignment. */
        unsigned char *shorts = calloc(1, 1 + 65536 * 3 - 1);
        assert(shorts);
        for (unsigned i = 0; i < 65536; i++) {
            put16(shorts + 1 + 3 * i, i);
        }
        id<MTLBuffer> sb = buffer(commands, shorts, 1 + 65536 * 3 - 1);
        free(shorts);
        defaults(sources);
        for (unsigned a = 0; a < 2; a++) {
            sources[a].buffer = sb;
            sources[a].offset = 1;
            sources[a].stride = 3;
            sources[a].count = 1;
            sources[a].format =
                a ? NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K :
                    NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1;
        }
        r = run(fetch, commands, sources, 65536, 0);
        out = values(r);
        for (unsigned i = 0; i < 65536; i++) {
            float signedValue = i < 32768 ? (float)i : (float)((int)i - 65536);
            check_float(out[i].attributes[0][0],
                        (float)((2.0 * signedValue + 1.0) / 65535.0));
            check_float(out[i].attributes[1][0], signedValue);
            for (unsigned a = 0; a < 2; a++) {
                check_float(out[i].attributes[a][1], 0);
                check_float(out[i].attributes[a][2], 0);
                check_float(out[i].attributes[a][3], 1);
            }
        }

        /* Signed component-count defaults (1..4), with overlapping strides. */
        unsigned char interleaved[18] = { 0 };
        for (unsigned i = 0; i < 8; i++) {
            put16(interleaved + 1 + 2 * i, 65535 - 100 * i);
        }
        id<MTLBuffer> shared =
            buffer(commands, interleaved, sizeof(interleaved));
        defaults(sources);
        for (unsigned a = 0; a < 8; a++) {
            sources[a].buffer = shared;
            sources[a].offset = 1;
            sources[a].stride = 2;
            sources[a].count = a % 4 + 1;
            sources[a].format =
                a < 4 ? NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1 :
                        NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K;
        }
        r = run(fetch, commands, sources, 4, 1);
        out = values(r);
        for (unsigned i = 0; i < 4; i++) {
            for (unsigned a = 0; a < 8; a++) {
                for (unsigned k = 0; k < 4; k++) {
                    float expected = k < sources[a].count ?
                                         -1.0f - 100 * (i + 1 + k) :
                                         k == 3;
                    if (k < sources[a].count && a < 4) {
                        expected = (float)((2.0 * expected + 1.0) / 65535.0);
                    }
                    check_float(out[i].attributes[a][k], expected);
                }
            }
        }

        /* Every 11/11/10 signed field, independently in x/y/z. The most
         * negative array values intentionally extend below -1 like GLSL. */
        unsigned char packed[1 + 2048 * 4];
        for (unsigned i = 0; i < 2048; i++) {
            unsigned y = (37 * i + 3) & 2047;
            unsigned z = (13 * i + 7) & 1023;
            put32(packed + 1 + 4 * i, i | (y << 11) | (z << 22));
        }
        id<MTLBuffer> cmp = buffer(commands, packed, sizeof(packed));
        defaults(sources);
        sources[2] = (NV2AMetalAttributeSource){
            .buffer = cmp,
            .offset = 1,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP,
            .count = 1,
            .stride = 4
        };
        r = run(fetch, commands, sources, 2048, 0);
        out = values(r);
        for (unsigned i = 0; i < 2048; i++) {
            float x = (float)(i < 1024 ? (int)i : (int)i - 2048) / 1023;
            unsigned ybits = (37 * i + 3) & 2047;
            float y =
                (float)(ybits < 1024 ? (int)ybits : (int)ybits - 2048) / 1023;
            unsigned zbits = (13 * i + 7) & 1023;
            float z =
                (float)(zbits < 512 ? (int)zbits : (int)zbits - 1024) / 511;
            check_float(out[i].attributes[2][0], x);
            check_float(out[i].attributes[2][1], y);
            check_float(out[i].attributes[2][2], z);
            check_float(out[i].attributes[2][3], 1);
        }

        /* Float data is copied bit-for-bit, including negative zero,
         * infinities, subnormals and quiet NaN payloads. Missing components use
         * (0,0,0,1). */
        const unsigned floatBits[] = { 0,          0x80000000, 0x7f800000,
                                       0xff800000, 0x7fc12345, 0xffc23456,
                                       1,          0x807fffff, 0x3f800000,
                                       0xc0200000, 0x7f7fffff, 0xff7fffff,
                                       0x00800000, 0x80000001, 0x3eaaaaab,
                                       0x40000000 };
        unsigned char floats[1 + 4 * sizeof(floatBits)];
        for (unsigned i = 0; i < 64; i++) {
            put32(floats + 1 + 4 * i, floatBits[i % 16]);
        }
        id<MTLBuffer> fb = buffer(commands, floats, sizeof(floats));
        defaults(sources);
        for (unsigned a = 0; a < 4; a++) {
            sources[a] = (NV2AMetalAttributeSource){
                .buffer = fb,
                .offset = 1,
                .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
                .count = a + 1,
                .stride = 16
            };
        }
        r = run(fetch, commands, sources, 16, 0);
        out = values(r);
        for (unsigned i = 0; i < 16; i++) {
            for (unsigned a = 0; a < 4; a++) {
                for (unsigned k = 0; k < 4; k++) {
                    unsigned actual;
                    memcpy(&actual, &out[i].attributes[a][k], sizeof(actual));
                    unsigned expected = k <= a ? floatBits[(4 * i + k) % 16] :
                                        k == 3 ? 0x3f800000 :
                                                 0;
                    assert(actual == expected);
                }
            }
        }

        /* Stride 0 converts only the first source element, ignoring vertex and
         * index offsets: D3D is unswizzled; compressed minima are clamped. */
        unsigned char minimum[4];
        put32(minimum, 1024u | (1024u << 11) | (512u << 22));
        id<MTLBuffer> mb = buffer(commands, minimum, sizeof(minimum));
        defaults(sources);
        sources[0] = (NV2AMetalAttributeSource){
            .buffer = ub,
            .offset = 1,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D,
            .count = 4
        };
        sources[1] = (NV2AMetalAttributeSource){
            .buffer = mb,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP,
            .count = 1
        };
        sources[2] = (NV2AMetalAttributeSource){
            .buffer = ub,
            .offset = 1,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
            .count = 3
        };
        sources[3] = (NV2AMetalAttributeSource){
            .buffer = sb,
            .offset = 1 + 3 * 32768,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1,
            .count = 1
        };
        sources[4] = (NV2AMetalAttributeSource){
            .buffer = sb,
            .offset = 1 + 3 * 32768,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K,
            .count = 1
        };
        sources[5] = (NV2AMetalAttributeSource){
            .buffer = fb,
            .offset = 1 + 9 * 4,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
            .count = 1
        };
        r = run(fetch, commands, sources, 4, 0xffffffffu - 3);
        out = values(r);
        for (unsigned i = 0; i < 4; i++) {
            for (unsigned k = 0; k < 4; k++) {
                check_float(out[i].attributes[0][k], 31 * k / 255.0f);
            }
            check_float(out[i].attributes[1][0], -1);
            check_float(out[i].attributes[1][1], -1);
            check_float(out[i].attributes[1][2], -1);
            check_float(out[i].attributes[2][2], 62 / 255.0f);
            check_float(out[i].attributes[2][3], 1);
            check_float(out[i].attributes[3][0], -1);
            check_float(out[i].attributes[4][0], -32768);
            check_float(out[i].attributes[5][0], -2.5f);
        }

        /* Indexed gathers: repeated/reordered indices, unsigned 16-bit values
         * above INT16_MAX, 32-bit values and byte offsets. */
        defaults(sources);
        sources[7] = (NV2AMetalAttributeSource){
            .buffer = sb,
            .offset = 1,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K,
            .count = 1,
            .stride = 3
        };
        for (unsigned indexSize = 2; indexSize <= 4; indexSize += 2) {
            const unsigned indices[] = { 50000, 0, 50000, 65533 };
            unsigned char indexBytes[17] = { 0 };
            for (unsigned i = 0; i < 4; i++) {
                if (indexSize == 2) {
                    put16(indexBytes + 1 + indexSize * i, indices[i]);
                } else {
                    put32(indexBytes + 1 + indexSize * i, indices[i]);
                }
            }
            id<MTLBuffer> ib = buffer(commands, indexBytes, 1 + 4 * indexSize);
            begin(commands);
            r = encode(fetch, commands, sources, 4, 2, ib, 1, indexSize);
            finish(commands);
            out = values(r);
            for (unsigned i = 0; i < 4; i++) {
                unsigned index = indices[i] + 2;
                check_float(out[i].attributes[7][0],
                            index < 32768 ? (float)index :
                                            (float)((int)index - 65536));
            }
        }

        /* GPU bounds faults never dereference the invalid source. Each bad
         * attribute is reported; UINT32_MAX catches index addition overflow. */
        sources[3] = (NV2AMetalAttributeSource){
            .buffer = ub,
            .offset = 1,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL,
            .count = 4,
            .stride = 7
        };
        unsigned char badIndex[16];
        put32(badIndex, 255);
        put32(badIndex + 4, 256);
        put32(badIndex + 8, 65536);
        put32(badIndex + 12, UINT32_MAX);
        id<MTLBuffer> ib = buffer(commands, badIndex, sizeof(badIndex));
        begin(commands);
        r = encode(fetch, commands, sources, 4, 1, ib, 0, 4);
        finish(commands);
        const unsigned *faults = r.faults.contents;
        assert(faults[0] == (1u << 3) && faults[1] == (1u << 3));
        assert(faults[2] == ((1u << 3) | (1u << 7)) && faults[3] == UINT32_MAX);
        out = r.attributes.contents;
        check_float(out[0].attributes[3][0], 0);
        check_float(out[0].attributes[3][3], 1);

        /* Fetch -> both native vertex paths in one submission, without CPU
         * readback. Multiple fetches also check argument-table snapshots. */
        const float positions[][4] = { { 1, 2, 4, 1 }, { 5, 6, 8, 1 } };
        id<MTLBuffer> pb = buffer(commands, positions, sizeof(positions));
        defaults(sources);
        sources[0] = (NV2AMetalAttributeSource){
            .buffer = pb,
            .format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F,
            .count = 4,
            .stride = 16
        };
        NV2AMetalVertexFixed *fixed =
            [[NV2AMetalVertexFixed alloc] initWithDevice:commands.device
                                                   error:&error];
        require(fixed != nil, error);
        NV2AMetalVertexProgram *program =
            [[NV2AMetalVertexProgram alloc] initWithDevice:commands.device
                                                     error:&error];
        require(program != nil, error);
        NV2AMetalFixedUniforms u = { 0 };
        u.common.surface_size[0] = u.common.surface_size[1] = 16;
        u.common.zmax = 16;
        u.common.point_scale = 1;
        u.common.point_size = 1;
        for (unsigned k = 0; k < 4; k++) {
            u.common.constants[NV_IGRAPH_XF_XFCTX_CMAT0 + k][k] = 1;
            u.common.constants[NV_IGRAPH_XF_XFCTX_MMAT0 + k][k] = 1;
            u.common.constants[NV_IGRAPH_XF_XFCTX_IMMAT0 + k][k] = 1;
        }
        /* MOV oPos, v0, FINAL: original four-DWORD token layout. */
        const uint32_t token[] = { 0, (1u << 21) | 27,
                                   (2u << 26) | (3u << 11) | (1u << 21) |
                                       (2u << 19) | (3u << 17) | 108,
                                   (1u << 28) | (2u << 30) | (1u << 11) |
                                       (15u << 12) | 1 };
        begin(commands);
        NV2AMetalFetchResult *first =
            encode(fetch, commands, sources, 1, 0, nil, 0, 0);
        NV2AMetalFetchResult *second =
            encode(fetch, commands, sources, 1, 1, nil, 0, 0);
        NV2AMetalFixedResult *f = [fixed encodeAttributes:first.attributes
                                                    count:1
                                                 uniforms:&u
                                                 commands:commands
                                                    error:&error];
        require(f != nil, error);
        NV2AMetalProgramResult *p = [program encodeTokens:token
                                                   length:1
                                                 uniforms:&u.common
                                               attributes:second.attributes
                                                    count:1
                                                 commands:commands
                                                    error:&error];
        require(p != nil, error);
        finish(commands);
        check_float(values(first)[0].attributes[0][0], 1);
        check_float(values(second)[0].attributes[0][0], 5);
        const NV2AMetalProgramOutput *fr = f.registers.contents;
        const NV2AMetalProgramOutput *pr = p.registers.contents;
        assert(fr->fault == 0 && pr->fault == 0);
        for (unsigned k = 0; k < 4; k++) {
            check_float(fr->registers[0][k], positions[0][k]);
            check_float(pr->registers[0][k], positions[1][k]);
        }

        /* Invalid formats, source and index spans, integer overflow and empty
         * draws are handled without opening a window or submitting bad work. */
        begin(commands);
        sources[0].count = 5;
        assert(![fetch encodeSources:sources
                               count:1
                         firstVertex:0
                             indices:nil
                         indexOffset:0
                           indexSize:0
                            commands:commands
                               error:&error]);
        assert(error);
        sources[0].count = 4;
        sources[0].format = 3;
        assert(![fetch encodeSources:sources
                               count:1
                         firstVertex:0
                             indices:nil
                         indexOffset:0
                           indexSize:0
                            commands:commands
                               error:&error]);
        sources[0].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D;
        sources[0].count = 3;
        assert(![fetch encodeSources:sources
                               count:1
                         firstVertex:0
                             indices:nil
                         indexOffset:0
                           indexSize:0
                            commands:commands
                               error:&error]);
        sources[0].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP;
        sources[0].count = 2;
        assert(![fetch encodeSources:sources
                               count:1
                         firstVertex:0
                             indices:nil
                         indexOffset:0
                           indexSize:0
                            commands:commands
                               error:&error]);
        sources[0].format = NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F;
        sources[0].count = 4;
        sources[0].offset = pb.length - 15;
        assert(![fetch encodeSources:sources
                               count:1
                         firstVertex:0
                             indices:nil
                         indexOffset:0
                           indexSize:0
                            commands:commands
                               error:&error]);
        sources[0].offset = NSUIntegerMax;
        assert(![fetch encodeSources:sources
                               count:1
                         firstVertex:0
                             indices:nil
                         indexOffset:0
                           indexSize:0
                            commands:commands
                               error:&error]);
        sources[0].offset = 0;
        assert(![fetch encodeSources:sources
                               count:3
                         firstVertex:0
                             indices:nil
                         indexOffset:0
                           indexSize:0
                            commands:commands
                               error:&error]);
        assert(![fetch encodeSources:sources
                               count:2
                         firstVertex:UINT32_MAX
                             indices:nil
                         indexOffset:0
                           indexSize:0
                            commands:commands
                               error:&error]);
        assert(![fetch encodeSources:sources
                               count:1
                         firstVertex:0
                             indices:nil
                         indexOffset:0
                           indexSize:2
                            commands:commands
                               error:&error]);
        assert(![fetch encodeSources:sources
                               count:1
                         firstVertex:0
                             indices:ib
                         indexOffset:0
                           indexSize:1
                            commands:commands
                               error:&error]);
        assert(![fetch encodeSources:sources
                               count:1
                         firstVertex:0
                             indices:ib
                         indexOffset:ib.length - 3
                           indexSize:4
                            commands:commands
                               error:&error]);
        assert(![fetch encodeSources:sources
                               count:1
                         firstVertex:0
                             indices:ib
                         indexOffset:NSUIntegerMax
                           indexSize:4
                            commands:commands
                               error:&error]);
        NV2AMetalFetchResult *empty =
            encode(fetch, commands, sources, 0, 0, nil, 0, 0);
        assert(empty.vertexCount == 0 && !empty.attributes && !empty.faults);
        [commands cancel];
        puts("Metal 4 vertex formats, constants, stride, indexed gather and "
             "native vertex handoff: PASS (offscreen)");
    }
    return 0;
}
