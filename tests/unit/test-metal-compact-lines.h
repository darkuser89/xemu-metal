/* Compact line carriers versus the unchanged six-record compute transport.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#ifndef TEST_METAL_COMPACT_LINES_H
#define TEST_METAL_COMPACT_LINES_H
#import "hw/xbox/nv2a/pgraph/metal/shader-library.h"
#include <math.h>

@interface NV2AMetalGeometry (CompactLineReference)
- (NSArray<NV2AMetalGeometryResult *> *)
    encodeRasterVertices:(id<MTLBuffer>)vertices
                   first:(NSUInteger)first
                   count:(NSUInteger)count
               primitive:(enum NV2AMetalPrimitive)primitive
                  config:(const NV2AMetalGeometryRasterConfig *)config
                  smooth:(BOOL)smooth
          firstProvoking:(BOOL)first
            zPerspective:(BOOL)perspective
                commands:(NV2AMetalCommands *)commands
                   error:(NSError **)error;
@end

static void cl_require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "Compact lines: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static BOOL cl_observe;
static NSUInteger cl_forbidden_bytes;
static unsigned cl_full_record_allocations;
static id (*cl_buffer)(id, SEL, NSUInteger, MTLResourceOptions);
static id cl_buffer_spy(id object, SEL selector, NSUInteger length,
                        MTLResourceOptions options)
{
    if (cl_observe && cl_forbidden_bytes && length == cl_forbidden_bytes)
        cl_full_record_allocations++;
    return cl_buffer(object, selector, length, options);
}
static unsigned cl_pack, cl_expand, cl_gather;
static NSMutableDictionary<NSValue *, NSString *> *cl_names, *cl_encoders;
static id (*cl_compute)(id, SEL, NSString *, NSError **);
static id cl_compute_spy(id object, SEL selector, NSString *name,
                         NSError **error)
{
    id result = cl_compute(object, selector, name, error);
    if (result)
        cl_names[[NSValue valueWithPointer:(__bridge const void *)result]] =
            name;
    return result;
}
static void (*cl_pipeline)(id, SEL, id);
static void cl_pipeline_spy(id object, SEL selector, id pipeline)
{
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)object];
    NSString *name =
        cl_names[[NSValue valueWithPointer:(__bridge const void *)pipeline]];
    if (name)
        cl_encoders[key] = name;
    else
        [cl_encoders removeObjectForKey:key];
    cl_pipeline(object, selector, pipeline);
}
static void (*cl_dispatch)(id, SEL, MTLSize, MTLSize);
static void cl_dispatch_spy(id object, SEL selector, MTLSize threads,
                            MTLSize group)
{
    NSString *name =
        cl_encoders[[NSValue valueWithPointer:(__bridge const void *)object]];
    if (cl_observe) {
        cl_pack += [name isEqualToString:@"nv2a_compact_lines"] ||
                   [name isEqualToString:@"nv2a_compact_indexed_lines"];
        cl_expand += [name isEqualToString:@"nv2a_expand_geometry"];
        cl_gather += [name isEqualToString:@"nv2a_vertex_stream_gather"];
    }
    cl_dispatch(object, selector, threads, group);
}
@interface CompactLineInput : NSObject
@property(nonatomic) id<MTLBuffer> source;
@property(nonatomic) NV2AMetalIndexedVertices *owner;
@property(nonatomic) NSData *map;
@property(nonatomic) NSUInteger first, count;
@end
@implementation CompactLineInput
@end
static CompactLineInput *cl_input(NV2AMetalCommands *commands,
                                  unsigned transport, unsigned scene,
                                  NSUInteger count)
{
    NSUInteger recordsCount = MAX(count, 20u);
    NSMutableData *storage =
        [NSMutableData dataWithLength:recordsCount * sizeof(NV2AMetalVertex)];
    NV2AMetalVertex *records = storage.mutableBytes;
    const float xy[8][2] = { { 3.5f, 4.5f },   { 28.5f, 7.5f },
                             { 6.5f, 26.5f },  { 26.5f, 23.5f },
                             { -8.5f, 10.5f }, { 18.5f, 2.5f },
                             { 16.5f, 16.5f }, { 30.5f, -4.5f } };
    for (unsigned i = 0; i < 8; i++) {
        NV2AMetalVertex *v = &records[i];
        float x = xy[i][0], y = xy[i][1], w = .5f + (i % 4) * .25f;
        if (scene == 1) {
            x = i & 1 ? 28.5f : 3.5f;
            y = i < 4 ? 10.5f : 20.5f;
        }
        if (scene == 3) {
            x = -100 - (float)i;
            y = -100;
        }
        if (scene == 6) {
            x = 16.5f;
            y = 16.5f;
        }
        if (scene == 8) {
            x = i & 1 ? 32 : 0;
            y = i & 2 ? 32 : 0;
        }
        v->screen[0] = x;
        v->screen[1] = y;
        v->screen[2] = 30000 + i * 1700;
        v->screen[3] = w;
        v->clip[0] = (x / 16 - 1) * w;
        v->clip[1] = (1 - y / 16) * w;
        v->clip[2] = .5f * w;
        v->clip[3] = w;
        if (scene == 2 && !(i & 1))
            v->clip[3] = -w;
        if (scene == 4 || scene == 5) {
            float scale = ldexpf(1, scene == 4 ? 60 : -60);
            for (unsigned k = 0; k < 4; k++)
                v->clip[k] *= scale;
        }
        if (scene == 7 && i < 4)
            v->clip[i % 4] = i & 1 ? INFINITY : NAN;
        if (scene == 9 && !(i & 1)) {
            v->clip[3] = 0;
            v->clip[0] = -1;
        }
        v->fog = (i + 1) / 9.f;
        v->point_size = 9;
        v->face = NV2AMetalFaceBack;
        v->slope = 999;
        for (unsigned k = 0; k < 4; k++) {
            v->color[0][k] = k == 3 ? .5f : (i + k) % 5 / 4.f;
            v->color[1][k] = k == 3 ? .75f : (i + 2 * k) % 7 / 6.f;
            v->color[2][k] = 1 - v->color[0][k];
            v->color[3][k] = 1 - v->color[1][k];
            for (unsigned t = 0; t < 4; t++)
                v->texcoord[t][k] = k == 3 ? 1 : (i * 3 + k + t) / 8.f;
            for (unsigned p = 0; p < 3; p++)
                v->plane[p][k] = 100 + p + k;
            if (k < 3)
                v->line_raster[k] = 77 + k;
        }
    }
    for (unsigned i = 8; i < recordsCount; i++)
        records[i] = records[i % 8];
    CompactLineInput *input = [CompactLineInput new];
    input.count = count;
    input.first = transport ? 5 : 0;
    NSError *error = nil;
    if (transport < 2) {
        input.source = [commands.device
            newBufferWithLength:(recordsCount + input.first) * sizeof(*records)
                        options:MTLResourceStorageModeShared];
        memset(input.source.contents, 0x5a, input.source.length);
        memcpy((uint8_t *)input.source.contents +
                   input.first * sizeof(*records),
               records, storage.length);
    } else {
        input.source =
            [commands.device newBufferWithLength:9 * sizeof(*records)
                                         options:MTLResourceStorageModeShared];
        memset(input.source.contents, 0x5a, input.source.length);
        for (unsigned i = 0; i < 8; i++)
            ((NV2AMetalVertex *)input.source.contents)[8 - i] = records[i];
        NSMutableData *map =
            [NSMutableData dataWithLength:(recordsCount + 5) * 4];
        uint32_t *values = map.mutableBytes;
        for (unsigned i = 0; i < recordsCount; i++)
            values[i + 5] = 8 - i % 8;
        input.map = map;
        input.owner =
            [[NV2AMetalIndexedVertices alloc] initWithVertices:input.source
                                                 physicalCount:9
                                                         remap:map
                                                         error:&error];
        cl_require(input.owner != nil, error);
    }
    if (transport == 1 || transport == 2) {
        id<MTLBuffer> private =
            [commands.device newBufferWithLength:input.source.length
                                         options:MTLResourceStorageModePrivate];
        cl_require(private &&
                       [commands addResource:input.source error:&error] &&
                       [commands addResource:private error:&error],
                   error);
        id<MTL4ComputeCommandEncoder> e =
            [commands.commandBuffer computeCommandEncoder];
        assert(e);
        [e barrierAfterQueueStages:MTLStageAll
                      beforeStages:MTLStageBlit
                 visibilityOptions:MTL4VisibilityOptionDevice];
        [e copyFromBuffer:input.source
                 sourceOffset:0
                     toBuffer:private
            destinationOffset:0
                         size:input.source.length];
        [e barrierAfterStages:MTLStageBlit
            beforeQueueStages:MTLStageAll
            visibilityOptions:MTL4VisibilityOptionDevice];
        [e endEncoding];
        input.source = private;
        if (input.owner) {
            input.owner =
                [[NV2AMetalIndexedVertices alloc] initWithVertices:private
                                                     physicalCount:9
                                                             remap:input.map
                                                             error:&error];
            cl_require(input.owner != nil, error);
        }
    }
    return input;
}
static id<MTLBuffer> cl_copy(NV2AMetalCommands *commands, id<MTLBuffer> source)
{
    if (!source)
        return nil;
    NSError *error = nil;
    id<MTLBuffer> result =
        [commands.device newBufferWithLength:source.length
                                     options:MTLResourceStorageModeShared];
    cl_require(result && [commands addResource:source error:&error] &&
                   [commands addResource:result error:&error],
               error);
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageBlit
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:source
             sourceOffset:0
                 toBuffer:result
        destinationOffset:0
                     size:source.length];
    [e barrierAfterStages:MTLStageBlit
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return result;
}
static id<MTLTexture> cl_attachment(id<MTLDevice> device, MTLPixelFormat format,
                                    unsigned samples)
{
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.width = d.height = 32;
    d.pixelFormat = format;
    d.sampleCount = samples;
    d.textureType =
        samples == 1 ? MTLTextureType2D : MTLTextureType2DMultisample;
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
              MTLTextureUsagePixelFormatView;
    id<MTLTexture> result = [device newTextureWithDescriptor:d];
    assert(result);
    return result;
}
static id<MTLComputePipelineState> cl_read_pipeline[2];
static void cl_read_libraries(NV2AMetalCommands *commands)
{
    NSMutableString *source = [NSMutableString
        stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\n"];
    for (unsigned ms = 0; ms < 2; ms++) {
        NSString *type = ms ? @"texture2d_ms" : @"texture2d";
        NSString *position = ms ? @"p,s" : @"p";
        [source
            appendFormat:
                @"kernel void read%u(%@<float> color [[texture(0)]], %@<float> "
                @"depth [[texture(1)]], %@<uint> stencil [[texture(2)]], "
                @"device uint *out [[buffer(0)]], uint i "
                @"[[thread_position_in_grid]]) {uint "
                @"sampleCount=%@;if(i>=1024*sampleCount)return;uint "
                @"pixel=i/sampleCount,s=i%%sampleCount;uint2 "
                @"p(pixel%%32,pixel/32);uint4 "
                @"c=as_type<uint4>(color.read(%@));out[6*i]=c.x;out[6*i+1]=c.y;"
                @"out[6*i+2]=c.z;out[6*i+3]=c.w;out[6*i+4]=as_type<uint>(depth."
                @"read(%@).x);out[6*i+5]=stencil.read(%@).x;}\n",
                ms, type, type, type, ms ? @"color.get_num_samples()" : @"1",
                position, position, position];
    }
    NSError *error = nil;
    id<MTL4Compiler> compiler =
        [commands.device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                             error:&error];
    cl_require(compiler != nil, error);
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = source;
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    ld.options.mathMode = MTLMathModeSafe;
    ld.options.mathFloatingPointFunctions =
        MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld
                                                          error:&error];
    cl_require(library != nil, error);
    for (unsigned ms = 0; ms < 2; ms++) {
        MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new];
        f.library = library;
        f.name = [NSString stringWithFormat:@"read%u", ms];
        MTL4ComputePipelineDescriptor *d = [MTL4ComputePipelineDescriptor new];
        d.computeFunctionDescriptor = f;
        cl_read_pipeline[ms] =
            [compiler newComputePipelineStateWithDescriptor:d
                                        compilerTaskOptions:nil
                                                      error:&error];
        cl_require(cl_read_pipeline[ms] != nil, error);
    }
}
static id<MTLBuffer> cl_read(NV2AMetalCommands *commands, id<MTLTexture> color,
                             id<MTLTexture> depth, unsigned samples)
{
    NSError *error = nil;
    id<MTLTexture> stencil =
        [depth newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8];
    assert(stencil);
    id<MTLBuffer> output =
        [commands.device newBufferWithLength:1024 * samples * 24
                                     options:MTLResourceStorageModeShared];
    assert(output);
    for (id r in @[ color, depth, stencil, output ])
        cl_require([commands addResource:r error:&error], error);
    MTL4ArgumentTableDescriptor *d = [MTL4ArgumentTableDescriptor new];
    d.maxBufferBindCount = 1;
    d.maxTextureBindCount = 3;
    d.initializeBindings = YES;
    id<MTL4ArgumentTable> args =
        [commands.device newArgumentTableWithDescriptor:d error:&error];
    cl_require(args && [commands keepAlive:args error:&error] &&
                   [commands keepAlive:cl_read_pipeline[samples > 1]
                                 error:&error],
               error);
    [args setAddress:output.gpuAddress atIndex:0];
    [args setTexture:color.gpuResourceID atIndex:0];
    [args setTexture:depth.gpuResourceID atIndex:1];
    [args setTexture:stencil.gpuResourceID atIndex:2];
    id<MTL4ComputeCommandEncoder> e =
        [commands.commandBuffer computeCommandEncoder];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageDispatch
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setArgumentTable:args];
    [e setComputePipelineState:cl_read_pipeline[samples > 1]];
    [e dispatchThreads:MTLSizeMake(1024 * samples, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [e barrierAfterStages:MTLStageDispatch
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    return output;
}
static NSUInteger cl_segments(enum NV2AMetalPrimitive primitive,
                              NSUInteger count)
{
    return primitive == NV2AMetalPrimitiveLines ? count / 2 :
           count < 2 ? 0 :
                       count - (primitive == NV2AMetalPrimitiveLineStrip);
}
static NV2AMetalGeometryResult *
cl_geometry(NV2AMetalCommands *commands, NV2AMetalGeometry *geometry,
            CompactLineInput *input, enum NV2AMetalPrimitive primitive,
            const NV2AMetalGeometryRasterConfig *config, BOOL smooth,
            BOOL first, BOOL w, BOOL direct)
{
    NSError *error = nil;
    NSArray *results = nil;
    cl_forbidden_bytes = direct ? cl_segments(primitive, input.count) * 6 *
                                      sizeof(NV2AMetalVertex) :
                                  0;
    cl_observe = YES;
    if (direct && input.owner) {
        NV2AMetalVertexStream *s =
            [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                    limit:input.count
                                                    error:&error];
        cl_require(s && [s appendIndexedVertices:input.owner
                                           first:input.first
                                           count:input.count
                                           error:&error],
                   error);
        NV2AMetalVertexSlice *slice =
            [s encodeSliceForDrawingWithCommands:commands error:&error];
        cl_require(slice != nil, error);
        results = [geometry encodeNativeRasterSlice:slice
                                          primitive:primitive
                                             config:config
                                             smooth:smooth
                                     firstProvoking:first
                                       zPerspective:w
                                           commands:commands
                                              error:&error];
    } else if (direct)
        results = [geometry encodeNativeRasterVertices:input.source
                                                 first:input.first
                                                 count:input.count
                                             primitive:primitive
                                                config:config
                                                smooth:smooth
                                        firstProvoking:first
                                          zPerspective:w
                                              commands:commands
                                                 error:&error];
    else {
        id<MTLBuffer> source = input.source;
        NSUInteger offset = input.first;
        if (input.owner && input.count) {
            NV2AMetalVertexStream *s =
                [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                        limit:input.count
                                                        error:&error];
            cl_require(s && [s appendIndexedVertices:input.owner
                                               first:input.first
                                               count:input.count
                                               error:&error],
                       error);
            source = [s encodeWithCommands:commands error:&error];
            cl_require(source || !input.count, error);
            offset = 0;
        }
        results = [geometry encodeRasterVertices:source
                                           first:offset
                                           count:input.count
                                       primitive:primitive
                                          config:config
                                          smooth:smooth
                                  firstProvoking:first
                                    zPerspective:w
                                        commands:commands
                                           error:&error];
    }
    cl_observe = NO;
    cl_forbidden_bytes = 0;
    cl_require(results.count == 1, error);
    return results[0];
}
static id<MTLTexture> cl_pattern(id<MTLDevice> device)
{
    MTLTextureDescriptor *d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                     width:32
                                    height:32
                                 mipmapped:YES];
    d.storageMode = MTLStorageModeShared;
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [device newTextureWithDescriptor:d];
    assert(texture);
    for (unsigned level = 0; level < texture.mipmapLevelCount; level++) {
        unsigned n = MAX(1u, 32u >> level);
        float values[32 * 32 * 4];
        for (unsigned i = 0; i < n * n; i++)
            for (unsigned k = 0; k < 4; k++)
                values[4 * i + k] =
                    k == 3 ? 1 : ((i * 37 + k * 53 + level * 71) & 255) / 255.f;
        [texture replaceRegion:MTLRegionMake2D(0, 0, n, n)
                   mipmapLevel:level
                     withBytes:values
                   bytesPerRow:n * 16];
    }
    return texture;
}
static void cl_packets(NSData *packets, NSData *expanded,
                       CompactLineInput *input,
                       enum NV2AMetalPrimitive primitive, BOOL smooth,
                       BOOL first)
{
    NSUInteger segments = cl_segments(primitive, input.count);
    assert(packets.length == segments * sizeof(NV2AMetalCompactLine) &&
           expanded.length >= segments * 6 * sizeof(NV2AMetalVertex));
    const NV2AMetalCompactLine *p = packets.bytes;
    const NV2AMetalVertex *v = expanded.bytes;
    for (NSUInteger segment = 0; segment < segments; segment++) {
        const NV2AMetalVertex *r = v + 6 * segment;
        assert(!!p[segment].valid == (r[0].line_raster[2] == 1));
        if (!p[segment].valid)
            continue;
        const unsigned order[] = { 0, 1, 2, 5 };
        for (unsigned corner = 0; corner < 4; corner++)
            assert(!memcmp(p[segment].clip[corner], r[order[corner]].clip, 8));
        assert(!memcmp(p[segment].p0, r[0].plane[0], 16) &&
               !memcmp(p[segment].p1, r[0].plane[1], 16) &&
               !memcmp(p[segment].p2, r[0].plane[2], 16));
        assert(!memcmp(&p[segment].slope, &r[0].slope, 4) &&
               p[segment].width == r[0].line_raster[0] &&
               p[segment].smooth == (unsigned)r[0].line_raster[1] &&
               p[segment].face == r[0].face &&
               p[segment].color_smooth == smooth);
        NSUInteger a =
            primitive == NV2AMetalPrimitiveLines ? segment * 2 : segment;
        NSUInteger b = primitive == NV2AMetalPrimitiveLineLoop ?
                           (segment + 1) % input.count :
                           a + 1;
        unsigned physical[2] = { (unsigned)a, (unsigned)b };
        if (input.owner) {
            const uint32_t *map = input.map.bytes;
            physical[0] = map[input.first + a];
            physical[1] = map[input.first + b];
        }
        assert(p[segment].source[0] == physical[0] &&
               p[segment].source[1] == physical[1]);
        if (!smooth)
            assert(p[segment].provoking == physical[first ? 0 : 1]);
        for (unsigned k = 0; k < 3; k++)
            assert(!p[segment].reserved[k]);
    }
}
typedef struct CompactLineCase {
    enum NV2AMetalPrimitive primitive;
    unsigned transport, scene, samples, profile, slices;
    NSUInteger count;
    float width;
    BOOL smoothLine, w, smooth, first;
} CompactLineCase;
@interface CompactLineOutput : NSObject
@property(nonatomic) NSData *pixels, *geometry;
@property(nonatomic) CompactLineInput *input;
@property(nonatomic) uint64_t query, changedColor, changedZeta;
@property(nonatomic) double seconds;
@end
@implementation CompactLineOutput
@end
static NV2AMetalPixelShader *cl_pixels[2];
static CompactLineOutput *cl_render(NV2AMetalCommands *commands,
                                    NV2AMetalGeometry *geometry,
                                    id<MTLTexture> pattern, CompactLineCase c,
                                    BOOL direct, unsigned repeats)
{
    NSError *error = nil;
    cl_require([commands beginWithError:&error] != nil, error);
    CompactLineInput *input = cl_input(commands, c.transport, c.scene, c.count);
    NV2AMetalGeometryRasterConfig config = { .front = NV2AMetalPolygonPoint,
                                             .back = NV2AMetalPolygonLine,
                                             .cullFront = YES,
                                             .cullBack = YES,
                                             .frontClockwise = YES,
                                             .lineWidth = c.width,
                                             .lineSmooth = c.smoothLine,
                                             .polygonSmooth = YES,
                                             .viewportWidth = 32,
                                             .viewportHeight = 32 };
    unsigned pack = cl_pack, expand = cl_expand, gather = cl_gather,
             allocations = cl_full_record_allocations;
    NV2AMetalGeometryResult *g =
        cl_geometry(commands, geometry, input, c.primitive, &config, c.smooth,
                    c.first, c.w, direct);
    NSUInteger segments = cl_segments(c.primitive, c.count),
               generated = segments * 6;
    assert(g.vertexCount == generated && g.verticesPerPrimitive == 6 &&
           g.primitiveCount == segments &&
           g.primitiveType == MTLPrimitiveTypeTriangle && g.expandedLines &&
           !g.expandedPolygons);
    if (direct) {
        assert(g.compactLines && g.lineCoverage.length ==
                                     segments * sizeof(NV2AMetalCompactLine));
        assert(cl_pack - pack == !!segments && cl_expand == expand &&
               cl_gather == gather &&
               cl_full_record_allocations == allocations);
        assert(!segments ?
                   (!g.vertices && !g.indexedVertices && !g.lineCoverage &&
                    !g.sourceVertexCount && !g.physicalVertexCount) :
                   (g.vertices == input.source &&
                    g.indexedVertices == input.owner &&
                    g.lineCoverage.storageMode == MTLStorageModePrivate &&
                    [g canUseLineCoverageForCommands:commands]));
        if (segments) {
            NSUInteger source = c.primitive == NV2AMetalPrimitiveLines ?
                                    c.count / 2 * 2 :
                                    c.count;
            assert(g.sourceVertexCount == source &&
                   g.firstVertex == (input.owner ? 0 : input.first) &&
                   g.indexOffset == (input.owner ? input.first : 0));
            assert(g.physicalVertexCount ==
                   (input.owner ? input.owner.physicalVertexCount : source));
            assert(g.lineCoverage.length < generated * sizeof(NV2AMetalVertex));
        }
    } else {
        assert(!g.compactLines && !g.lineCoverage && cl_pack == pack &&
               cl_expand - expand == !!segments &&
               cl_gather - gather == (input.owner && c.count ? 1u : 0u));
    }
    BOOL timing = repeats > 1;
    id<MTLBuffer> geometryReadback =
        timing ? nil : cl_copy(commands, direct ? g.lineCoverage : g.vertices);
    if (!cl_pixels[c.samples > 1])
        cl_pixels[c.samples > 1] = [[NV2AMetalPixelShader alloc]
            initWithDevice:commands.device
               colorFormat:MTLPixelFormatRGBA8Unorm
               depthFormat:MTLPixelFormatDepth32Float_Stencil8
               sampleCount:c.samples
                     error:&error];
    NV2AMetalPixelShader *pixel = cl_pixels[c.samples > 1];
    cl_require(pixel != nil, error);
    id<MTLTexture> color = cl_attachment(commands.device,
                                         MTLPixelFormatRGBA8Unorm, c.samples),
                   depth = cl_attachment(commands.device,
                                         MTLPixelFormatDepth32Float_Stencil8,
                                         c.samples);
    uint64_t initial = 7;
    id<MTLBuffer> query =
        [commands.device newBufferWithBytes:&initial
                                     length:8
                                    options:MTLResourceStorageModeShared];
    assert(query);
    cl_require([commands addResource:query error:&error], error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(.91, .92, .93, .94);
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.depthAttachment.clearDepth = 1;
    pass.stencilAttachment.texture = depth;
    pass.stencilAttachment.loadAction = MTLLoadActionClear;
    pass.stencilAttachment.storeAction = MTLStoreActionStore;
    pass.stencilAttachment.clearStencil = 0x11;
    pass.visibilityResultBuffer = query;
    pass.visibilityResultType = MTLVisibilityResultTypeAccumulate;
    NV2AMetalPixelUniforms u = { 0 };
    u.combiner.final_inputs[0] =
        c.profile == 1 ? PS_REGISTER_T0 :
        c.profile == 2 ? (PS_REGISTER_FOG | PS_CHANNEL_ALPHA) :
        c.profile == 3 ? PS_REGISTER_V1 :
                         PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    u.smooth_shading = c.smooth;
    u.two_side = 1;
    u.z_perspective = c.w;
    u.depth_format =
        (unsigned[]){ NV2AMetalPixelDepthD16, NV2AMetalPixelDepthD24,
                      NV2AMetalPixelDepthF16,
                      NV2AMetalPixelDepthF24 }[c.profile % 4];
    u.depth_offset = 128;
    u.depth_factor = 1.5f;
    u.surface_scale[0] = c.profile & 1 ? 2 : 1;
    u.surface_scale[1] = c.profile & 1 ? 3 : 1;
    u.clip_range[1] = u.clip_range[3] = 16777215;
    u.clip_regions[0][2] = u.clip_regions[0][3] = 32;
    for (unsigned i = 0; i < 4; i++) {
        u.textures[i].dimension = 2;
        u.textures[i].scale = 1;
        u.fog_color[i] = i / 4.f;
    }
    NV2AMetalPixelTexture textures[4] = { 0 };
    if (c.profile == 1) {
        u.combiner.shader_stage_program = PS_TEXTUREMODES_PROJECT2D;
        u.textures[0].sampling =
            (NV2AMetalSamplingUniforms){ .enabled = 1,
                                         .address = { 1, 1, 3 },
                                         .min_linear = 1,
                                         .mag_linear = 1,
                                         .mip_filter = 2,
                                         .anisotropy = 4 };
        textures[0].texture = pattern;
    }
    NV2AMetalDrawConfig dc = { 0 };
    dc.control[0] = NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE |
                    NV_PGRAPH_CONTROL_0_ZENABLE |
                    NV_PGRAPH_CONTROL_0_ZWRITEENABLE |
                    NV_PGRAPH_CONTROL_0_STENCIL_WRITE_ENABLE | 7 << 16;
    dc.control[1] = NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE | 5 << 4 |
                    0x13 << 8 | 0xff << 16 | 0xffu << 24;
    dc.control[2] = 1 | 1 << 4 | 4 << 8;
    dc.blend = NV_PGRAPH_BLEND_EN | 2 | 4 << 4 | 5 << 8;
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&dc
                                             error:&error];
    cl_require(state != nil, error);
    NV2AMetalPixelRasterClass raster = direct ?
                                           NV2AMetalPixelRasterCompactLine :
                                           NV2AMetalPixelRasterExpandedLine;
    NSMutableArray<NV2AMetalPixelDraw *> *draws = [NSMutableArray new];
    NSUInteger firsts[3] = { 0, 1, 8 },
               counts[3] = { generated, generated > 2 ? generated - 2 : 0,
                             generated > 8 ? generated - 8 : 0 };
    unsigned parts = generated ? (c.slices ? 3 : 1) : 0;
    if (c.slices) {
        firsts[0] = 0;
        counts[0] = MIN(1u, generated);
        firsts[1] = MIN(1u, generated);
        counts[1] = MIN(7u, generated - firsts[1]);
        firsts[2] = MIN(8u, generated);
        counts[2] = generated - firsts[2];
    }
    for (unsigned part = 0; part < parts; part++) {
        /* The old ExpandedLine shader's endpoint IDs require a whole binding.
         * Its public offset path rebases the buffer for odd offsets. Keep the
         * unchanged full compute transport, changing only generated draw IDs,
         * exactly as the new compact consumer does for arbitrary slices. */
        NV2AMetalPixelDraw *prepared = [pixel
                 prepareGeometry:g
                          offset:direct ?
                                     firsts[part] * sizeof(NV2AMetalVertex) :
                                     0
                           count:direct ? counts[part] : generated
                        uniforms:&u
                        textures:textures
                            pass:pass
                       drawState:state
                     rasterClass:raster
            ignorePolygonCulling:YES
                        commands:commands
                           error:&error];
        cl_require(prepared != nil, error);
        if (!direct && c.slices) {
            [prepared setValue:@(firsts[part]) forKey:@"firstVertex"];
            [prepared setValue:@(counts[part]) forKey:@"vertexCount"];
        }
        [draws addObject:prepared];
    }
    id<MTL4RenderCommandEncoder> e =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    assert(e);
    [e barrierAfterQueueStages:MTLStageAll
                  beforeStages:MTLStageAll
             visibilityOptions:MTL4VisibilityOptionDevice];
    [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    for (unsigned repeat = 0; repeat < repeats; repeat++)
        for (NV2AMetalPixelDraw *prepared in draws)
            cl_require([prepared encodeWithRenderEncoder:e
                                                commands:commands
                                                   error:&error],
                       error);
    [e barrierAfterStages:MTLStageAll
        beforeQueueStages:MTLStageAll
        visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
    id<MTLBuffer> readback =
        timing ? nil : cl_read(commands, color, depth, c.samples);
    cl_require([commands submitWithError:&error] &&
                   [commands waitUntilIdleWithError:&error],
               error);
    double elapsed = gpuSeconds;
    if (timing) {
        cl_require([commands beginWithError:&error] != nil, error);
        geometryReadback =
            cl_copy(commands, direct ? g.lineCoverage : g.vertices);
        readback = cl_read(commands, color, depth, c.samples);
        cl_require([commands submitWithError:&error] &&
                       [commands waitUntilIdleWithError:&error],
                   error);
    }
    CompactLineOutput *result = [CompactLineOutput new];
    result.input = input;
    result.seconds = elapsed;
    result.query = *(const uint64_t *)query.contents;
    assert(result.query >= 7);
    result.query -= 7;
    result.pixels = [NSData dataWithBytes:readback.contents
                                   length:readback.length];
    result.geometry = geometryReadback ?
                          [NSData dataWithBytes:geometryReadback.contents
                                         length:geometryReadback.length] :
                          [NSData data];
    const uint32_t *words = readback.contents;
    for (unsigned i = 0; i < 1024 * c.samples; i++) {
        const float *value = (const float *)(words + 6 * i);
        result.changedColor += fabsf(value[0] - .91f) > .01f ||
                               fabsf(value[1] - .92f) > .01f ||
                               fabsf(value[2] - .93f) > .01f;
        result.changedZeta +=
            words[6 * i + 4] != 0x3f800000 || words[6 * i + 5] != 0x11;
    }
    return result;
}
static uint64_t cl_visible[4], cl_changed_color[4], cl_changed_zeta[4];
static unsigned cl_pairs;
static void cl_pair(NV2AMetalCommands *commands, NV2AMetalGeometry *geometry,
                    id<MTLTexture> pattern, CompactLineCase c)
{
    CompactLineOutput *output[2];
    for (unsigned order = 0; order < 2; order++) {
        unsigned direct = (order + cl_pairs) & 1;
        output[direct] = cl_render(commands, geometry, pattern, c, direct, 1);
    }
    if (![output[0].pixels isEqualToData:output[1].pixels] ||
        output[0].query != output[1].query) {
        fprintf(stderr,
                "Compact line pair%u primitive%u transport%u scene%u samples%u "
                "profile%u slices%u count%lu width%g lineSmooth%d W%d smooth%d "
                "first%d query%llu/%llu\n",
                cl_pairs, c.primitive, c.transport, c.scene, c.samples,
                c.profile, c.slices, (unsigned long)c.count, c.width,
                c.smoothLine, c.w, c.smooth, c.first,
                (unsigned long long)output[0].query,
                (unsigned long long)output[1].query);
        abort();
    }
    cl_packets(output[1].geometry, output[0].geometry, output[1].input,
               c.primitive, c.smooth, c.first);
    unsigned mode = c.smoothLine ? (c.w ? 3 : 1) : c.w ? 2 : 0;
    cl_visible[mode] += output[1].query;
    cl_changed_color[mode] += output[1].changedColor;
    cl_changed_zeta[mode] += output[1].changedZeta;
    cl_pairs++;
}
static void cl_guards(NV2AMetalCommands *commands, NV2AMetalGeometry *geometry)
{
    NSError *error = nil;
    cl_require([commands beginWithError:&error] != nil, error);
    CompactLineInput *input = cl_input(commands, 3, 0, 17);
    NV2AMetalGeometryRasterConfig config = { .front = NV2AMetalPolygonFill,
                                             .back = NV2AMetalPolygonFill,
                                             .lineWidth = 1,
                                             .viewportWidth = 32,
                                             .viewportHeight = 32 };
    NV2AMetalGeometryResult *g =
        cl_geometry(commands, geometry, input, NV2AMetalPrimitiveLineLoop,
                    &config, NO, YES, YES, YES);
    assert([g canUseLineCoverageForCommands:commands]);
    NV2AMetalPixelShader *pixel = cl_pixels[0];
    assert(pixel);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture =
        cl_attachment(commands.device, MTLPixelFormatRGBA8Unorm, 1);
    pass.depthAttachment.texture =
        cl_attachment(commands.device, MTLPixelFormatDepth32Float_Stencil8, 1);
    pass.stencilAttachment.texture = pass.depthAttachment.texture;
    NV2AMetalPixelUniforms u = { .clip_range = { 0, 16777215, 0, 16777215 },
                                 .surface_scale = { 1, 1 },
                                 .z_perspective = 1 };
    u.combiner.final_inputs[0] = PS_REGISTER_V0;
    u.combiner.final_inputs[1] = (PS_REGISTER_V0 | PS_CHANNEL_ALPHA) << 8;
    for (unsigned i = 0; i < 4; i++) {
        u.textures[i].dimension = 2;
        u.textures[i].scale = 1;
    }
    NV2AMetalPixelTexture textures[4] = { 0 };
    NV2AMetalDrawConfig dc = { 0 };
    NV2AMetalDrawState *state =
        [[NV2AMetalDrawState alloc] initWithDevice:commands.device
                                            config:&dc
                                             error:&error];
    cl_require(state != nil, error);
    assert(![pixel prepareGeometry:g
                             offset:0
                              count:g.vertexCount
                           uniforms:&u
                           textures:textures
                               pass:pass
                          drawState:state
                        rasterClass:NV2AMetalPixelRasterExpandedLine
               ignorePolygonCulling:YES
                           commands:commands
                              error:&error] &&
           error);
    error = nil;
    assert(![pixel encodeVertices:g.vertices
                             offset:0
                              count:6
                          primitive:MTLPrimitiveTypeTriangle
                           uniforms:&u
                           textures:textures
                               pass:pass
                          drawState:state
                        rasterClass:NV2AMetalPixelRasterCompactLine
               ignorePolygonCulling:YES
                           commands:commands
                              error:&error] &&
           error);
    error = nil;
    assert(![pixel prepareGeometry:g
                             offset:1
                              count:1
                           uniforms:&u
                           textures:textures
                               pass:pass
                          drawState:state
                        rasterClass:NV2AMetalPixelRasterCompactLine
               ignorePolygonCulling:YES
                           commands:commands
                              error:&error] &&
           error);
    error = nil;
    assert(![pixel prepareGeometry:g
                             offset:g.vertexCount * sizeof(NV2AMetalVertex)
                              count:1
                           uniforms:&u
                           textures:textures
                               pass:pass
                          drawState:state
                        rasterClass:NV2AMetalPixelRasterCompactLine
               ignorePolygonCulling:YES
                           commands:commands
                              error:&error] &&
           error);
    error = nil;
    NV2AMetalPixelDraw *empty =
        [pixel prepareGeometry:g
                          offset:g.vertexCount * sizeof(NV2AMetalVertex)
                           count:0
                        uniforms:&u
                        textures:textures
                            pass:pass
                       drawState:state
                     rasterClass:NV2AMetalPixelRasterCompactLine
            ignorePolygonCulling:YES
                        commands:commands
                           error:&error];
    cl_require(empty != nil, error);
    assert(!empty.vertexCount);
    NV2AMetalCommands *other =
        [[NV2AMetalCommands alloc] initWithDevice:commands.device error:&error];
    cl_require(other && [other beginWithError:&error], error);
    assert(![g canUseLineCoverageForCommands:other]);
    error = nil;
    assert(![pixel prepareGeometry:g
                             offset:0
                              count:g.vertexCount
                           uniforms:&u
                           textures:textures
                               pass:pass
                          drawState:state
                        rasterClass:NV2AMetalPixelRasterCompactLine
               ignorePolygonCulling:YES
                           commands:other
                              error:&error] &&
           error);
    [other cancel];
    [commands cancel];
    error = nil;
    cl_require([commands beginWithError:&error] != nil, error);
    assert(![g canUseLineCoverageForCommands:commands]);
    assert(![pixel prepareGeometry:g
                             offset:0
                              count:g.vertexCount
                           uniforms:&u
                           textures:textures
                               pass:pass
                          drawState:state
                        rasterClass:NV2AMetalPixelRasterCompactLine
               ignorePolygonCulling:YES
                           commands:commands
                              error:&error] &&
           error);
    error = nil;
    id<MTL4RenderCommandEncoder> e =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    assert(e);
    assert(![empty encodeWithRenderEncoder:e commands:commands error:&error] &&
           error);
    [e endEncoding];
    [commands cancel];
    cl_require([commands beginWithError:&error] != nil, error);
    input = cl_input(commands, 0, 0, 17);
    unsigned before = cl_pack + cl_expand + cl_gather;
    for (unsigned test = 0; test < 9; test++) {
        config.lineWidth = test == 0 ? -1 :
                           test == 1 ? NAN :
                           test == 2 ? INFINITY :
                                       1;
        config.viewportWidth = test >= 3 && test != 6 && test != 8 ? 0 : 32;
        config.viewportHeight = 32;
        BOOL w = test >= 3;
        NSUInteger count = test == 4 ? 0 : test == 5 ? 1 : test == 8 ? 21 : 17;
        NSUInteger first = test == 6 ? NSUIntegerMax : 0;
        if (test == 7) {
            config.viewportWidth = 16385;
            config.lineWidth = 2;
        }
        error = nil;
        cl_observe = YES;
        assert(![geometry encodeNativeRasterVertices:input.source
                                               first:first
                                               count:count
                                           primitive:NV2AMetalPrimitiveLines
                                              config:&config
                                              smooth:NO
                                      firstProvoking:NO
                                        zPerspective:w
                                            commands:commands
                                               error:&error] &&
               error);
        cl_observe = NO;
    }
    assert(before == cl_pack + cl_expand + cl_gather);
    [commands cancel];
}
static void cl_timing(NV2AMetalCommands *commands, NV2AMetalGeometry *geometry,
                      id<MTLTexture> pattern)
{
    for (unsigned profile = 0; profile < 8; profile++) {
        CompactLineCase c = { .primitive =
                                  NV2AMetalPrimitiveLines + profile % 3,
                              .transport = profile & 1 ? 3 : 0,
                              .samples = 1,
                              .count = profile < 4 ? 17 : 4097,
                              .width = profile % 4 == 0 ? 3 :
                                       profile % 4 == 3 ? 3 :
                                                          1,
                              .smoothLine =
                                  profile % 4 == 1 || profile % 4 == 3,
                              .w = profile % 4 >= 2,
                              .smooth = profile & 1,
                              .first = !(profile & 1) };
        double times[2][9];
        for (unsigned trial = 0; trial < 11; trial++) {
            CompactLineOutput *output[2];
            for (unsigned order = 0; order < 2; order++) {
                unsigned direct = (order + trial) & 1;
                output[direct] =
                    cl_render(commands, geometry, pattern, c, direct, 8);
                assert(output[direct].seconds > 0);
                if (trial >= 2)
                    times[direct][trial - 2] = output[direct].seconds;
            }
            assert([output[0].pixels isEqualToData:output[1].pixels] &&
                   output[0].query == output[1].query);
            cl_packets(output[1].geometry, output[0].geometry, output[1].input,
                       c.primitive, c.smooth, c.first);
        }
        double ratios[9];
        for (unsigned i = 0; i < 9; i++)
            ratios[i] = times[1][i] / times[0][i];
        qsort(times[0], 9, sizeof(double), compare_double);
        qsort(times[1], 9, sizeof(double), compare_double);
        qsort(ratios, 9, sizeof(double), compare_double);
        printf("Compact line timing profile%u n%lu topology%u indexed%u "
               "width%g smooth%d W%d: old/compact median %.6f/%.6fms, paired "
               "ratio %.5f [%.5f,%.5f];2warmups/9 AB-BA pairs,readbacks "
               "outside interval PASS\n",
               profile, (unsigned long)c.count, c.primitive, c.transport >= 2,
               c.width, c.smoothLine, c.w, times[0][4] * 1000,
               times[1][4] * 1000, ratios[4], ratios[2], ratios[6]);
        fflush(stdout);
    }
}
static void compact_lines_tests(BOOL timing)
{
    NSError *error = nil;
    NV2AMetalCommands *commands =
        [[NV2AMetalCommands alloc] initWithError:&error];
    cl_require(commands != nil, error);
    NV2AMetalGeometry *geometry =
        [[NV2AMetalGeometry alloc] initWithDevice:commands.device error:&error];
    cl_require(geometry != nil, error);
    cl_read_libraries(commands);
    id<MTLTexture> pattern = cl_pattern(commands.device);
    cl_require([commands beginWithError:&error] != nil, error);
    id e = [commands.commandBuffer computeCommandEncoder];
    Method methods[] = {
        class_getInstanceMethod(NV2AMetalShaderLibrary.class,
                                @selector(computeFunction:error:)),
        class_getInstanceMethod(object_getClass(e),
                                @selector(setComputePipelineState:)),
        class_getInstanceMethod(
            object_getClass(e),
            @selector(dispatchThreads:threadsPerThreadgroup:)),
        class_getInstanceMethod(MTL4CommitOptions.class,
                                @selector(addFeedbackHandler:)),
        class_getInstanceMethod(object_getClass(commands.device),
                                @selector(newBufferWithLength:options:))
    };
    [e endEncoding];
    [commands cancel];
    IMP replacements[] = { (IMP)cl_compute_spy, (IMP)cl_pipeline_spy,
                           (IMP)cl_dispatch_spy, (IMP)feedback_handler,
                           (IMP)cl_buffer_spy };
    IMP originals[5];
    cl_names = [NSMutableDictionary new];
    cl_encoders = [NSMutableDictionary new];
    for (unsigned i = 0; i < 5; i++) {
        assert(methods[i]);
        originals[i] = method_setImplementation(methods[i], replacements[i]);
    }
    cl_compute = (void *)originals[0];
    cl_pipeline = (void *)originals[1];
    cl_dispatch = (void *)originals[2];
    original_feedback = (void *)originals[3];
    cl_buffer = (void *)originals[4];
    cl_pairs = cl_pack = cl_expand = cl_gather = cl_full_record_allocations = 0;
    memset(cl_visible, 0, sizeof(cl_visible));
    memset(cl_changed_color, 0, sizeof(cl_changed_color));
    memset(cl_changed_zeta, 0, sizeof(cl_changed_zeta));
    @try {
        for (unsigned topology = 0; topology < 3; topology++)
            for (unsigned transport = 0; transport < 4; transport++)
                for (unsigned mode = 0; mode < 4; mode++)
                    for (unsigned shade = 0; shade < 2; shade++) {
                        CompactLineCase c = {
                            .primitive = NV2AMetalPrimitiveLines + topology,
                            .transport = transport,
                            .samples = (mode + transport + shade) & 1 ? 4 : 1,
                            .profile = (mode + shade) % 4,
                            .count = 17,
                            .width = mode == 0 || mode == 3 ? 3 : 0,
                            .smoothLine = mode == 1 || mode == 3,
                            .w = mode >= 2,
                            .smooth = shade,
                            .first = !shade
                        };
                        cl_pair(commands, geometry, pattern, c);
                    }
        for (unsigned topology = 0; topology < 3; topology++)
            for (unsigned scene = 0; scene < 10; scene++) {
                CompactLineCase c = { .primitive =
                                          NV2AMetalPrimitiveLines + topology,
                                      .transport = scene % 4,
                                      .scene = scene,
                                      .samples = scene & 1 ? 4 : 1,
                                      .profile = scene % 4,
                                      .count = 17,
                                      .width = scene & 1 ? 2.5f : 3,
                                      .smoothLine = scene & 2,
                                      .w = scene & 4,
                                      .smooth = scene & 1,
                                      .first = scene & 2,
                                      .slices = scene == 0 || scene == 8 };
                cl_pair(commands, geometry, pattern, c);
            }
        const float widths[] = { 0, 1.49f, 1.5f, 2.5f, 31.5f, 16384 };
        for (unsigned topology = 0; topology < 3; topology++)
            for (unsigned width = 0; width < 6; width++) {
                CompactLineCase c = { .primitive =
                                          NV2AMetalPrimitiveLines + topology,
                                      .transport = 3,
                                      .samples = width & 1 ? 4 : 1,
                                      .profile = width % 4,
                                      .count = 17,
                                      .width = widths[width],
                                      .smoothLine = YES,
                                      .w = width & 1,
                                      .first = width & 2 };
                cl_pair(commands, geometry, pattern, c);
            }
        const unsigned counts[] = { 0, 1, 2, 3, 17 };
        for (unsigned topology = 0; topology < 3; topology++)
            for (unsigned count = 0; count < 5; count++) {
                CompactLineCase c = { .primitive =
                                          NV2AMetalPrimitiveLines + topology,
                                      .samples = 1,
                                      .count = counts[count],
                                      .width = 2,
                                      .w = YES,
                                      .smooth = YES };
                cl_pair(commands, geometry, pattern, c);
            }
        cl_guards(commands, geometry);
        CompactLineCase retry = { .primitive = NV2AMetalPrimitiveLineLoop,
                                  .transport = 2,
                                  .samples = 4,
                                  .profile = 1,
                                  .count = 17,
                                  .width = 3,
                                  .smoothLine = YES,
                                  .w = YES,
                                  .smooth = YES,
                                  .slices = 1 };
        cl_pair(commands, geometry, pattern, retry);
        for (unsigned mode = 0; mode < 4; mode++)
            assert(cl_visible[mode] && cl_changed_color[mode] &&
                   cl_changed_zeta[mode]);
        assert(cl_pairs == 160);
        printf("Compact lines:%u exact color/depth/stencil PER-SAMPLE/query "
               "pairs,1x/4x; borrowed Shared/Private/offset/remap,128B packet "
               "vs unchanged6-record compute "
               "metadata,1pack/0expand/0gather,Widths0-16384/Smooth/W/flat/"
               "textured/fog/clip/nonfinite/global-slices,stale/foreign/cancel/"
               "bounds/retry PASS\n",
               cl_pairs);
        printf("Compact line visibility "
               "wide/smooth/W/combined:%llu/%llu/%llu/%llu samples; each group "
               "changed color+zeta PASS\n",
               (unsigned long long)cl_visible[0],
               (unsigned long long)cl_visible[1],
               (unsigned long long)cl_visible[2],
               (unsigned long long)cl_visible[3]);
        fflush(stdout);
        if (timing)
            cl_timing(commands, geometry, pattern);
    } @finally {
        cl_observe = NO;
        for (unsigned i = 0; i < 5; i++)
            method_setImplementation(methods[i], originals[i]);
        cl_names = cl_encoders = nil;
        cl_pixels[0] = cl_pixels[1] = nil;
        cl_read_pipeline[0] = cl_read_pipeline[1] = nil;
    }
}
#endif
