/* SPDX-License-Identifier: LGPL-2.0-or-later */

#import "geometry.h"
#import "surface-cache.h"
#import "vertex-stream.h"
#import "shader-library.h"
#include "geometry-source.h"
#include <stdint.h>
#include <stddef.h>
#include <math.h>

_Static_assert(sizeof(NV2AMetalPolygonProjection) == 68,
               "CPU/MSL polygon projection");
_Static_assert(sizeof(NV2AMetalVertex) == 244, "CPU/MSL vertex layout");
_Static_assert(sizeof(NV2AMetalCompactLine) == 128,
               "CPU/MSL compact line layout");
_Static_assert(offsetof(NV2AMetalCompactLine, source) == 96,
               "CPU/MSL compact line source offset");
_Static_assert(sizeof(NV2AMetalCompactPolygon) == 128,
               "CPU/MSL compact polygon layout");
_Static_assert(offsetof(NV2AMetalCompactPolygon, source) == 96,
               "CPU/MSL compact polygon source offset");
_Static_assert(offsetof(NV2AMetalVertex, plane) == 176, "CPU/MSL plane offset");
_Static_assert(offsetof(NV2AMetalVertex, line_raster) == 228,
               "CPU/MSL expanded line metadata offset");
_Static_assert(sizeof(NV2AMetalGeometryUniforms) == 60,
               "CPU/MSL geometry layout");

static void geometry_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.geometry"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
}

static BOOL valid_raster_config(const NV2AMetalGeometryRasterConfig *c,
                                NSError **error)
{
    if (!c || c->front < NV2AMetalPolygonFill ||
        c->front > NV2AMetalPolygonLine || c->back < NV2AMetalPolygonFill ||
        c->back > NV2AMetalPolygonLine || !isfinite(c->lineWidth) ||
        c->lineWidth < 0 || c->lineWidth > 16384 ||
        ((c->lineWidth > 1 || c->lineSmooth || c->polygonSmooth) &&
         (!c->viewportWidth || !c->viewportHeight || c->viewportWidth > 16384 ||
          c->viewportHeight > 16384))) {
        geometry_error(error, @"Invalid native polygon raster modes");
        return NO;
    }
    return YES;
}

static BOOL direct_polygon_mode(enum NV2AMetalPolygonMode mode,
                                const NV2AMetalGeometryRasterConfig *c,
                                BOOL zPerspective)
{
    return mode == NV2AMetalPolygonPoint ||
           (mode == NV2AMetalPolygonFill && !c->polygonSmooth) ||
           (mode == NV2AMetalPolygonLine && c->lineWidth <= 1 &&
            !c->lineSmooth && !zPerspective);
}

/* With different front/back modes, each output pass already rejects the
 * opposite face. A pass for a face disabled by NV2A culling has no raster
 * effects, so it need not transport any vertices or coverage carriers. */
static BOOL skip_culled_mixed_pass(const NV2AMetalGeometryRasterConfig *c,
                                  unsigned pass)
{
    return c->front != c->back &&
           (pass ? c->cullBack : c->cullFront);
}

@interface NV2AMetalGeometryResult ()
@property(nonatomic, readwrite, strong, nullable) id<MTLBuffer>
    polygonProjections;
@property(nonatomic, readwrite, strong, nullable) id<MTLBuffer> polygonFacing;
@property(nonatomic, readwrite) BOOL compactLines;
@property(nonatomic, readwrite) BOOL compactPolygons;
@property(nonatomic, readwrite) enum NV2AMetalPrimitive sourcePrimitive;
@property(nonatomic, readwrite, strong, nullable) id<MTLBuffer> lineCoverage;
@property(nonatomic, readwrite, strong, nullable) id<MTLBuffer> polygonCoverage;
@property(nonatomic, weak) NV2AMetalCommands *coverageCommands;
@property(nonatomic) uint64_t coverageSerial;
@property(nonatomic, readwrite) NSUInteger firstVertex;
@property(nonatomic, readwrite) NSUInteger sourceVertexCount;
@property(nonatomic, readwrite, strong, nullable) NV2AMetalIndexedVertices *indexedVertices;
@property(nonatomic, readwrite) NSUInteger physicalVertexCount, indexOffset;
@property(nonatomic, readwrite) BOOL directPoints;
@property(nonatomic, readwrite) BOOL directTriangles;
@property(nonatomic, readwrite) unsigned directTriangleOptions;
@property(nonatomic, readwrite) unsigned directQuadOptions;
@property(nonatomic, readwrite) unsigned directPolygonOptions;
@property(nonatomic, readwrite) NV2AMetalGeometryDirectLineMode directLineMode;
@property(nonatomic, readwrite) unsigned directLineOptions;
- (nullable instancetype)initWithContinuationResult:
    (NV2AMetalGeometryResult *)result;
- (BOOL)matchesContinuationResult:(NV2AMetalGeometryResult *)result;
@end

@implementation NV2AMetalGeometryResult
- (BOOL)canUseLineCoverageForCommands:(NV2AMetalCommands *)commands
{
    return _compactLines && commands && commands == _coverageCommands &&
           commands.commandBuffer &&
           commands.recordingSerial == _coverageSerial;
}
- (BOOL)canUsePolygonCoverageForCommands:(NV2AMetalCommands *)commands
{
    return _compactPolygons && commands && commands == _coverageCommands &&
           commands.commandBuffer &&
           commands.recordingSerial == _coverageSerial;
}
- (instancetype)initWithVertices:(id<MTLBuffer>)vertices
                           count:(NSUInteger)count
                            type:(MTLPrimitiveType)type
                         polygon:(enum NV2AMetalPolygonMode)polygon
                    perPrimitive:(NSUInteger)perPrimitive
                   expandedLines:(BOOL)expandedLines
                expandedPolygons:(BOOL)expandedPolygons
{
    self = [super init];
    if (self) {
        _vertices = vertices;
        _vertexCount = count;
        _sourceVertexCount = count;
        _physicalVertexCount = count;
        _primitiveType = type;
        _polygonMode = polygon;
        _verticesPerPrimitive = perPrimitive;
        _primitiveCount = perPrimitive ? count / perPrimitive : 0;
        _expandedLines = expandedLines;
        _expandedPolygons = expandedPolygons;
    }
    return self;
}
- (instancetype)initWithContinuationResult:(NV2AMetalGeometryResult *)result
{
    self = [self initWithVertices:result->_vertices
                            count:result->_vertexCount
                             type:result->_primitiveType
                          polygon:result->_polygonMode
                     perPrimitive:result->_verticesPerPrimitive
                    expandedLines:result->_expandedLines
                 expandedPolygons:result->_expandedPolygons];
    if (self) {
        _primitiveCount = result->_primitiveCount;
        _sourceVertexCount = result->_sourceVertexCount;
        _physicalVertexCount = result->_physicalVertexCount;
        _indexOffset = result->_indexOffset;
        _firstVertex = result->_firstVertex;
        _indexedVertices = result->_indexedVertices;
        _polygonProjections = result->_polygonProjections;
        _polygonFacing = result->_polygonFacing;
        _compactLines = result->_compactLines;
        _compactPolygons = result->_compactPolygons;
        _sourcePrimitive = result->_sourcePrimitive;
        _lineCoverage = result->_lineCoverage;
        _polygonCoverage = result->_polygonCoverage;
        _coverageCommands = result->_coverageCommands;
        _coverageSerial = result->_coverageSerial;
        _directPoints = result->_directPoints;
        _directTriangles = result->_directTriangles;
        _directTriangleOptions = result->_directTriangleOptions;
        _directQuadOptions = result->_directQuadOptions;
        _directPolygonOptions = result->_directPolygonOptions;
        _directLineMode = result->_directLineMode;
        _directLineOptions = result->_directLineOptions;
    }
    return self;
}
- (BOOL)matchesContinuationResult:(NV2AMetalGeometryResult *)result
{
    return _vertices == result->_vertices &&
           _vertexCount == result->_vertexCount &&
           _primitiveType == result->_primitiveType &&
           _polygonMode == result->_polygonMode &&
           _primitiveCount == result->_primitiveCount &&
           _verticesPerPrimitive == result->_verticesPerPrimitive &&
           _expandedLines == result->_expandedLines &&
           _expandedPolygons == result->_expandedPolygons &&
           _sourceVertexCount == result->_sourceVertexCount &&
           _physicalVertexCount == result->_physicalVertexCount &&
           _indexOffset == result->_indexOffset &&
           _firstVertex == result->_firstVertex &&
           _indexedVertices == result->_indexedVertices &&
           _polygonProjections == result->_polygonProjections &&
           _polygonFacing == result->_polygonFacing &&
           _compactLines == result->_compactLines &&
           _compactPolygons == result->_compactPolygons &&
           _sourcePrimitive == result->_sourcePrimitive &&
           _lineCoverage == result->_lineCoverage &&
           _polygonCoverage == result->_polygonCoverage &&
           _coverageCommands == result->_coverageCommands &&
           _coverageSerial == result->_coverageSerial &&
           _directPoints == result->_directPoints &&
           _directTriangles == result->_directTriangles &&
           _directTriangleOptions == result->_directTriangleOptions &&
           _directQuadOptions == result->_directQuadOptions &&
           _directPolygonOptions == result->_directPolygonOptions &&
           _directLineMode == result->_directLineMode &&
           _directLineOptions == result->_directLineOptions;
}
@end

@interface NV2AMetalGeometryContinuation ()
@property(nonatomic, weak) NV2AMetalSurfaceCache *surfaceCache;
@property(nonatomic, weak) NV2AMetalCommands *commands;
@property(nonatomic, strong) NV2AMetalSurfaceRecording *recording;
@property(nonatomic) uint64_t serial;
@property(nonatomic) BOOL consumed;
@property(nonatomic, strong) NSArray<NV2AMetalGeometryResult *> *original;
@property(nonatomic, strong) NSArray<NV2AMetalGeometryResult *> *items;
@property(nonatomic, strong) NSArray<NV2AMetalGeometryResult *> *prepared;
- (nullable instancetype)initWithResults:
                             (NSArray<NV2AMetalGeometryResult *> *)results
                            surfaceCache:(NV2AMetalSurfaceCache *)surfaceCache
                                commands:(NV2AMetalCommands *)commands;
@end

@implementation NV2AMetalGeometryContinuation
- (instancetype)initWithResults:(NSArray<NV2AMetalGeometryResult *> *)results
                   surfaceCache:(NV2AMetalSurfaceCache *)surfaceCache
                       commands:(NV2AMetalCommands *)commands
{
    self = [super init];
    if (!self)
        return nil;
    _original = results;
    _items = [results copy];
    NSMutableArray *prepared = [NSMutableArray new];
    if (!_items || !prepared)
        return nil;
    BOOL compact = NO;
    for (NV2AMetalGeometryResult *result in _items) {
        if (result.class != NV2AMetalGeometryResult.class ||
            (result.compactLines &&
             ![result canUseLineCoverageForCommands:commands]) ||
            (result.compactPolygons &&
             ![result canUsePolygonCoverageForCommands:commands]))
            return nil;
        compact |= result.vertexCount &&
                   (result.compactLines || result.compactPolygons);
        NV2AMetalGeometryResult *copy =
            [[NV2AMetalGeometryResult alloc] initWithContinuationResult:result];
        if (!copy)
            return nil;
        [prepared addObject:copy];
    }
    if (!compact)
        return nil;
    _prepared = [prepared copy];
    if (!_prepared)
        return nil;
    _surfaceCache = surfaceCache;
    _commands = commands;
    _recording = surfaceCache.recording;
    _serial = commands.recordingSerial;
    return self;
}
@end

@implementation NV2AMetalGeometry {
    id<MTLDevice> _device;
    NV2AMetalShaderLibrary *_module;
    id<MTLComputePipelineState> _pipeline, _polygonFacing;
    id<MTLComputePipelineState> _directPolygonFacing[2];
    id<MTLComputePipelineState> _compactLinePipelines[2];
    id<MTLComputePipelineState> _compactPolygonLinePipelines[2];
    id<MTLComputePipelineState> _compactPolygonFillPipelines[2];
    id<MTL4ArgumentTable> _arguments;
    id<MTLBuffer> _emptyProjections;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }
    if (![device supportsFamily:MTLGPUFamilyApple7] ||
        ![device supportsFamily:MTLGPUFamilyMetal4] ||
        !device.hasUnifiedMemory) {
        geometry_error(error, @"Metal 4 geometry requires Apple Silicon");
        return nil;
    }
    _device = device;
    MTL4ArgumentTableDescriptor *arguments = [MTL4ArgumentTableDescriptor new];
    arguments.maxBufferBindCount = 6;
    arguments.initializeBindings = YES;
    _arguments = [device newArgumentTableWithDescriptor:arguments error:error];
    _emptyProjections =
        [device newBufferWithLength:sizeof(NV2AMetalPolygonProjection)
                            options:MTLResourceStorageModePrivate];
    if (!_emptyProjections) {
        geometry_error(error, @"Could not allocate empty polygon projection");
        return nil;
    }
    return _arguments ? self : nil;
}

- (nullable NV2AMetalGeometryResult *)
    encodeVertices:(id<MTLBuffer>)vertices
             count:(NSUInteger)count
         primitive:(enum NV2AMetalPrimitive)primitive
           polygon:(enum NV2AMetalPolygonMode)polygon
            smooth:(BOOL)smooth
    firstProvoking:(BOOL)firstProvoking
      zPerspective:(BOOL)zPerspective
          commands:(NV2AMetalCommands *)commands
             error:(NSError **)error
{
    return [self encodeVertices:vertices
                          first:0
                          count:count
                      primitive:primitive
                        polygon:polygon
                         smooth:smooth
                 firstProvoking:firstProvoking
                   zPerspective:zPerspective
                       faceMask:0
                 frontClockwise:NO
                      lineWidth:1
                     lineSmooth:NO
                  polygonSmooth:NO
                  viewportWidth:0
                 viewportHeight:0
                       commands:commands
                          error:error];
}
- (NV2AMetalGeometryResult *)
    encodeCompactLines:(id<MTLBuffer>)vertices
                 first:(NSUInteger)first
                 count:(NSUInteger)count
             primitive:(enum NV2AMetalPrimitive)primitive
                config:(const NV2AMetalGeometryRasterConfig *)c
                smooth:(BOOL)smooth
        firstProvoking:(BOOL)firstProvoking
          zPerspective:(BOOL)zPerspective
              commands:(NV2AMetalCommands *)commands
       indexedVertices:(NV2AMetalIndexedVertices *)indexed
                 error:(NSError **)error
{
    return [self encodeCompactLines:vertices
                              first:first
                              count:count
                          primitive:primitive
                             config:c
                             smooth:smooth
                     firstProvoking:firstProvoking
                       zPerspective:zPerspective
                           commands:commands
                    indexedVertices:indexed
                      polygonFacing:nil
                              error:error];
}
- (NV2AMetalGeometryResult *)
    encodeCompactLines:(id<MTLBuffer>)vertices
                 first:(NSUInteger)first
                 count:(NSUInteger)count
             primitive:(enum NV2AMetalPrimitive)primitive
                config:(const NV2AMetalGeometryRasterConfig *)c
                smooth:(BOOL)smooth
        firstProvoking:(BOOL)firstProvoking
          zPerspective:(BOOL)zPerspective
              commands:(NV2AMetalCommands *)commands
       indexedVertices:(NV2AMetalIndexedVertices *)indexed
         polygonFacing:(id<MTLBuffer>)faceBuffer
                 error:(NSError **)error
{
    BOOL polygon = primitive >= NV2AMetalPrimitiveTriangles;
    BOOL quad = primitive == NV2AMetalPrimitiveQuads ||
                primitive == NV2AMetalPrimitiveQuadStrip;
    NSUInteger edges =
        polygon && primitive != NV2AMetalPrimitivePolygon ? (quad ? 4 : 3) : 1;
    NSUInteger groups =
        primitive == NV2AMetalPrimitiveLines ?
            count / 2 :
        primitive <= NV2AMetalPrimitiveLineStrip ?
            (count < 2 ? 0 :
                         count - (primitive == NV2AMetalPrimitiveLineStrip)) :
        primitive == NV2AMetalPrimitiveTriangles ? count / 3 :
        primitive == NV2AMetalPrimitiveQuads     ? count / 4 :
        primitive == NV2AMetalPrimitiveQuadStrip ?
                                               (count < 4 ? 0 : count / 2 - 1) :
        primitive == NV2AMetalPrimitivePolygon ? (count < 2 ? 0 : count) :
        count < 3                              ? 0 :
                                                 count - 2;
    NSUInteger segments = groups * edges;
    BOOL genuine = primitive == NV2AMetalPrimitivePolygon;
    if ((genuine && segments &&
         (!faceBuffer || faceBuffer.device != _device ||
          faceBuffer.length != sizeof(uint32_t) ||
          faceBuffer.storageMode != MTLStorageModePrivate)) ||
        (!genuine && faceBuffer)) {
        geometry_error(error, @"Invalid compact polygon face input");
        return nil;
    }
    if (!c->viewportWidth || !c->viewportHeight || c->viewportWidth > 16384 ||
        c->viewportHeight > 16384 || segments > UINT32_MAX / 6 ||
        segments > _device.maxBufferLength / sizeof(NV2AMetalCompactLine)) {
        geometry_error(error,
                       @"Invalid compact line viewport or generated span");
        return nil;
    }
    NV2AMetalGeometryResult *result = [[NV2AMetalGeometryResult alloc]
        initWithVertices:segments ? vertices : nil
                   count:segments * 6
                    type:MTLPrimitiveTypeTriangle
                 polygon:polygon ? NV2AMetalPolygonLine : NV2AMetalPolygonFill
            perPrimitive:6 * edges
           expandedLines:YES
        expandedPolygons:NO];
    result.compactLines = YES;
    result.sourcePrimitive = primitive;
    result.coverageCommands = commands;
    result.coverageSerial = commands.recordingSerial;
    result.sourceVertexCount =
        !segments                                ? 0 :
        primitive == NV2AMetalPrimitiveLines     ? groups * 2 :
        primitive <= NV2AMetalPrimitiveLineStrip ? count :
        primitive == NV2AMetalPrimitiveTriangles ? groups * 3 :
        primitive == NV2AMetalPrimitiveQuads     ? groups * 4 :
        primitive == NV2AMetalPrimitiveQuadStrip ? groups * 2 + 2 :
        primitive == NV2AMetalPrimitivePolygon   ? count :
                                                   groups + 2;
    result.physicalVertexCount = !segments ? 0 :
                                 indexed   ? indexed.physicalVertexCount :
                                             result.sourceVertexCount;
    result.firstVertex = segments && !indexed ? first : 0;
    result.indexOffset = segments && indexed ? first : 0;
    result.indexedVertices = segments ? indexed : nil;
    result.directLineOptions =
        polygon ? 0 :
                  (smooth ? NV2AMetalDirectLineSmooth : 0) |
                      (firstProvoking ? NV2AMetalDirectLineFirst : 0) |
                      (primitive == NV2AMetalPrimitiveLineStrip ?
                           NV2AMetalDirectLineStrip :
                       primitive == NV2AMetalPrimitiveLineLoop ?
                           NV2AMetalDirectLineLoop :
                           0);
    if (!segments)
        return result;
    if (!_module)
        _module = [NV2AMetalShaderLibrary sharedWithDevice:_device
                                                    source:metal_shader_source
                                                     error:error];
    if (!_module)
        return nil;
    unsigned variant = indexed != nil;
    id<MTLComputePipelineState> pipeline =
        polygon ? _compactPolygonLinePipelines[variant] :
                  _compactLinePipelines[variant];
    if (!pipeline) {
        NSString *name = polygon ?
                             (indexed ? @"nv2a_compact_indexed_polygon_lines" :
                                        @"nv2a_compact_polygon_lines") :
                             (indexed ? @"nv2a_compact_indexed_lines" :
                                        @"nv2a_compact_lines");
        pipeline = [_module computeFunction:name error:error];
        if (polygon)
            _compactPolygonLinePipelines[variant] = pipeline;
        else
            _compactLinePipelines[variant] = pipeline;
    }
    if (!pipeline)
        return nil;
    id<MTLBuffer> packets =
        [_device newBufferWithLength:segments * sizeof(NV2AMetalCompactLine)
                             options:MTLResourceStorageModePrivate];
    if (!packets) {
        geometry_error(error, @"Could not allocate compact line carriers");
        return nil;
    }
    NV2AMetalGeometryUniforms uniforms = {
        .primitive = primitive,
        .polygon = polygon ? NV2AMetalPolygonLine : NV2AMetalPolygonFill,
        .smooth = smooth,
        .first_provoking = firstProvoking,
        .z_perspective = zPerspective,
        .input_count = (unsigned)result.sourceVertexCount,
        .primitive_count = (unsigned)groups,
        .output_per_primitive = (unsigned)(6 * edges),
        .face_mask = !polygon || (!c->cullFront && !c->cullBack) ? 0 :
                     c->cullFront && c->cullBack                 ? 4 :
                     c->cullFront                                ? 2 :
                                                                   1,
        .front_clockwise = c->frontClockwise,
        .viewport = { (float)c->viewportWidth, (float)c->viewportHeight },
        .line_width = c->lineWidth ? c->lineWidth : 1,
        .line_smooth = c->lineSmooth
    };
    NSUInteger offset = 0;
    id<MTLBuffer> constants = [commands uploadBytes:&uniforms
                                             length:sizeof(uniforms)
                                             offset:&offset
                                              error:error];
    if (!constants || ![commands addResource:vertices error:error] ||
        ![commands addResource:packets error:error] ||
        (faceBuffer && ![commands addResource:faceBuffer error:error]) ||
        (indexed && (![commands addResource:indexed.indices error:error] ||
                     ![commands keepAlive:indexed error:error])) ||
        ![commands keepAlive:self error:error])
        return nil;
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        geometry_error(error, @"Could not create compact line encoder");
        return nil;
    }
    [_arguments setAddress:vertices.gpuAddress +
                           (indexed ? 0 : first * sizeof(NV2AMetalVertex))
                   atIndex:0];
    [_arguments setAddress:packets.gpuAddress atIndex:1];
    [_arguments setAddress:constants.gpuAddress + offset atIndex:2];
    if (indexed)
        [_arguments
            setAddress:indexed.indices.gpuAddress + first * sizeof(uint32_t)
               atIndex:3];
    if (polygon)
        [_arguments setAddress:faceBuffer ? faceBuffer.gpuAddress :
                                            constants.gpuAddress + offset
                       atIndex:4];
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageDispatch
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder setArgumentTable:_arguments];
    [encoder setComputePipelineState:pipeline];
    [encoder dispatchThreads:MTLSizeMake(groups, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(
                                  MIN(groups, pipeline.threadExecutionWidth), 1,
                                  1)];
    [encoder barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    result.lineCoverage = packets;
    return result;
}
- (NV2AMetalGeometryResult *)
    encodeCompactPolygonFill:(id<MTLBuffer>)vertices
                       first:(NSUInteger)first
                       count:(NSUInteger)count
                   primitive:(enum NV2AMetalPrimitive)primitive
                      config:(const NV2AMetalGeometryRasterConfig *)c
                      smooth:(BOOL)smooth
              firstProvoking:(BOOL)firstProvoking
                zPerspective:(BOOL)zPerspective
                    commands:(NV2AMetalCommands *)commands
             indexedVertices:(NV2AMetalIndexedVertices *)indexed
               polygonFacing:(id<MTLBuffer>)faceBuffer
                       error:(NSError **)error
{
    BOOL quad = primitive == NV2AMetalPrimitiveQuads ||
                primitive == NV2AMetalPrimitiveQuadStrip;
    BOOL genuine = primitive == NV2AMetalPrimitivePolygon;
    NSUInteger groups =
        primitive == NV2AMetalPrimitiveTriangles ? count / 3 :
        primitive == NV2AMetalPrimitiveQuads     ? count / 4 :
        primitive == NV2AMetalPrimitiveQuadStrip ?
                                               (count < 4 ? 0 : count / 2 - 1) :
        count < 3 ? 0 :
                    count - 2;
    NSUInteger parts = quad ? 2 : 1;
    if (!c->viewportWidth || !c->viewportHeight || c->viewportWidth > 16384 ||
        c->viewportHeight > 16384 || groups > UINT32_MAX / (6 * parts) ||
        groups >
            _device.maxBufferLength / sizeof(NV2AMetalCompactPolygon) / parts ||
        groups > _device.maxBufferLength / sizeof(NV2AMetalPolygonProjection) /
                     parts ||
        (genuine && groups &&
         (!faceBuffer || faceBuffer.device != _device ||
          faceBuffer.length != sizeof(uint32_t) ||
          faceBuffer.storageMode != MTLStorageModePrivate)) ||
        (!genuine && faceBuffer)) {
        geometry_error(error, @"Invalid compact polygon fill span or facing");
        return nil;
    }
    NSUInteger carriers = groups * parts;
    NV2AMetalGeometryResult *result = [[NV2AMetalGeometryResult alloc]
        initWithVertices:carriers ? vertices : nil
                   count:carriers * 6
                    type:MTLPrimitiveTypeTriangle
                 polygon:NV2AMetalPolygonFill
            perPrimitive:6 * parts
           expandedLines:NO
        expandedPolygons:YES];
    result.compactPolygons = YES;
    result.sourcePrimitive = primitive;
    result.coverageCommands = commands;
    result.coverageSerial = commands.recordingSerial;
    result.sourceVertexCount =
        !carriers                                ? 0 :
        primitive == NV2AMetalPrimitiveTriangles ? groups * 3 :
        primitive == NV2AMetalPrimitiveQuads     ? groups * 4 :
        primitive == NV2AMetalPrimitiveQuadStrip ? groups * 2 + 2 :
                                                   groups + 2;
    result.physicalVertexCount = !carriers ? 0 :
                                 indexed   ? indexed.physicalVertexCount :
                                             result.sourceVertexCount;
    result.firstVertex = carriers && !indexed ? first : 0;
    result.indexOffset = carriers && indexed ? first : 0;
    result.indexedVertices = carriers ? indexed : nil;
    if (!carriers)
        return result;
    if (!_module)
        _module = [NV2AMetalShaderLibrary sharedWithDevice:_device
                                                    source:metal_shader_source
                                                     error:error];
    if (!_module)
        return nil;
    unsigned variant = indexed != nil;
    if (!_compactPolygonFillPipelines[variant])
        _compactPolygonFillPipelines[variant] = [_module
            computeFunction:indexed ? @"nv2a_compact_indexed_polygon_fill" :
                                      @"nv2a_compact_polygon_fill"
                      error:error];
    id<MTLComputePipelineState> pipeline =
        _compactPolygonFillPipelines[variant];
    if (!pipeline)
        return nil;
    id<MTLBuffer> packets =
        [_device newBufferWithLength:carriers * sizeof(NV2AMetalCompactPolygon)
                             options:MTLResourceStorageModePrivate];
    id<MTLBuffer> projections = [_device
        newBufferWithLength:carriers * sizeof(NV2AMetalPolygonProjection)
                    options:MTLResourceStorageModePrivate];
    if (!packets || !projections) {
        geometry_error(error, @"Could not allocate compact polygon carriers");
        return nil;
    }
    NV2AMetalGeometryUniforms uniforms = {
        .primitive = primitive,
        .polygon = NV2AMetalPolygonFill,
        .smooth = smooth,
        .first_provoking = firstProvoking,
        .z_perspective = zPerspective,
        .input_count = (unsigned)result.sourceVertexCount,
        .primitive_count = (unsigned)groups,
        .output_per_primitive = (unsigned)(6 * parts),
        .face_mask = (!c->cullFront && !c->cullBack) ? 0 :
                     c->cullFront && c->cullBack     ? 4 :
                     c->cullFront                    ? 2 :
                                                       1,
        .front_clockwise = c->frontClockwise,
        .viewport = { (float)c->viewportWidth, (float)c->viewportHeight },
        .polygon_smooth = YES
    };
    NSUInteger offset = 0;
    id<MTLBuffer> constants = [commands uploadBytes:&uniforms
                                             length:sizeof(uniforms)
                                             offset:&offset
                                              error:error];
    if (!constants || ![commands addResource:vertices error:error] ||
        ![commands addResource:packets error:error] ||
        ![commands addResource:projections error:error] ||
        (faceBuffer && ![commands addResource:faceBuffer error:error]) ||
        (indexed && (![commands addResource:indexed.indices error:error] ||
                     ![commands keepAlive:indexed error:error])) ||
        ![commands keepAlive:self error:error])
        return nil;
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        geometry_error(error, @"Could not create compact polygon fill encoder");
        return nil;
    }
    [_arguments setAddress:vertices.gpuAddress +
                           (indexed ? 0 : first * sizeof(NV2AMetalVertex))
                   atIndex:0];
    [_arguments setAddress:packets.gpuAddress atIndex:1];
    [_arguments setAddress:constants.gpuAddress + offset atIndex:2];
    if (indexed)
        [_arguments
            setAddress:indexed.indices.gpuAddress + first * sizeof(uint32_t)
               atIndex:3];
    [_arguments setAddress:faceBuffer ? faceBuffer.gpuAddress :
                                        constants.gpuAddress + offset
                   atIndex:4];
    [_arguments setAddress:projections.gpuAddress atIndex:5];
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageDispatch
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder setArgumentTable:_arguments];
    [encoder setComputePipelineState:pipeline];
    [encoder dispatchThreads:MTLSizeMake(groups, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(
                                  MIN(groups, pipeline.threadExecutionWidth), 1,
                                  1)];
    [encoder barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    result.polygonCoverage = packets;
    result.polygonProjections = projections;
    return result;
}
- (id<MTLBuffer>)encodePolygonFacing:(id<MTLBuffer>)vertices
                               first:(NSUInteger)first
                               count:(NSUInteger)count
                           clockwise:(BOOL)clockwise
                            commands:(NV2AMetalCommands *)commands
                     indexedVertices:(NV2AMetalIndexedVertices *)indexed
                               error:(NSError **)error
{
    if (!_module)
        _module = [NV2AMetalShaderLibrary sharedWithDevice:_device
                                                    source:metal_shader_source
                                                     error:error];
    if (!_module)
        return nil;
    unsigned variant = indexed != nil;
    if (!_directPolygonFacing[variant])
        _directPolygonFacing[variant] = [_module
            computeFunction:indexed ? @"nv2a_direct_indexed_polygon_face" :
                                      @"nv2a_direct_polygon_face"
                      error:error];
    if (!_directPolygonFacing[variant])
        return nil;
    id<MTLBuffer> facing =
        [_device newBufferWithLength:sizeof(uint32_t)
                             options:MTLResourceStorageModePrivate];
    if (!facing) {
        geometry_error(error, @"Could not allocate direct polygon facing");
        return nil;
    }
    NV2AMetalGeometryUniforms uniforms = { .input_count = (unsigned)count,
                                           .front_clockwise = clockwise };
    NSUInteger offset = 0;
    id<MTLBuffer> constants = [commands uploadBytes:&uniforms
                                             length:sizeof(uniforms)
                                             offset:&offset
                                              error:error];
    if (!constants || ![commands addResource:vertices error:error] ||
        ![commands addResource:facing error:error] ||
        (indexed && (![commands addResource:indexed.indices error:error] ||
                     ![commands keepAlive:indexed error:error])) ||
        ![commands keepAlive:self error:error])
        return nil;
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        geometry_error(error, @"Could not create polygon facing encoder");
        return nil;
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageDispatch
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [_arguments setAddress:vertices.gpuAddress +
                           (indexed ? 0 : first * sizeof(NV2AMetalVertex))
                   atIndex:0];
    [_arguments setAddress:facing.gpuAddress atIndex:1];
    [_arguments setAddress:constants.gpuAddress + offset atIndex:2];
    if (indexed)
        [_arguments
            setAddress:indexed.indices.gpuAddress + first * sizeof(uint32_t)
               atIndex:3];
    [encoder setArgumentTable:_arguments];
    [encoder setComputePipelineState:_directPolygonFacing[variant]];
    [encoder dispatchThreads:MTLSizeMake(1, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [encoder barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return facing;
}
/* Validate every generated mode before allocating or encoding any carrier.
 * Unchanged direct point/fill/thin-wire modes keep their original paths. */
- (NSArray<NV2AMetalGeometryResult *> *)
    encodeCompactPolygonRaster:(id<MTLBuffer>)vertices
                         first:(NSUInteger)first
                         count:(NSUInteger)count
                     primitive:(enum NV2AMetalPrimitive)primitive
                        config:(const NV2AMetalGeometryRasterConfig *)c
                        smooth:(BOOL)smooth
                firstProvoking:(BOOL)firstProvoking
                  zPerspective:(BOOL)zPerspective
                      commands:(NV2AMetalCommands *)commands
               indexedVertices:(NV2AMetalIndexedVertices *)indexed
                         error:(NSError **)error
{
    if (!c->viewportWidth || !c->viewportHeight || c->viewportWidth > 16384 ||
        c->viewportHeight > 16384) {
        geometry_error(error, @"Compact polygons require a valid viewport");
        return nil;
    }
    BOOL genuine = primitive == NV2AMetalPrimitivePolygon;
    BOOL quad = primitive == NV2AMetalPrimitiveQuads ||
                primitive == NV2AMetalPrimitiveQuadStrip;
    unsigned modes = c->front == c->back ? 1 : 2;
    BOOL hasOutput = NO;
    for (unsigned i = 0; i < modes; i++) {
        enum NV2AMetalPolygonMode mode = i ? c->back : c->front;
        BOOL wire = mode == NV2AMetalPolygonLine;
        NSUInteger groups = primitive == NV2AMetalPrimitiveTriangles ?
                                count / 3 :
                            primitive == NV2AMetalPrimitiveQuads ?
                                count / 4 :
                            primitive == NV2AMetalPrimitiveQuadStrip ?
                                (count < 4 ? 0 : count / 2 - 1) :
                            genuine && wire ? (count < 2 ? 0 : count) :
                            count < 3       ? 0 :
                                              count - 2;
        BOOL compactWire =
            wire && (c->lineWidth > 1 || c->lineSmooth || zPerspective);
        BOOL compactFill = mode == NV2AMetalPolygonFill && c->polygonSmooth;
        NSUInteger per = wire ? (genuine ? 2 :
                                 quad    ? 8 :
                                           6) *
                                    (compactWire ? 3 : 1) :
                         mode == NV2AMetalPolygonPoint ?
                                (quad ? 4 : 3) :
                                (quad ? 6 : 3) * (compactFill ? 2 : 1);
        if (groups > UINT32_MAX / per ||
            (compactWire && groups > _device.maxBufferLength /
                                         sizeof(NV2AMetalCompactLine) /
                                         (per / 6)) ||
            (compactFill &&
             (groups > _device.maxBufferLength /
                           sizeof(NV2AMetalCompactPolygon) / (per / 6) ||
              groups > _device.maxBufferLength /
                           sizeof(NV2AMetalPolygonProjection) / (per / 6)))) {
            geometry_error(error, @"Compact polygon mode exceeds its GPU span");
            return nil;
        }
        hasOutput |= groups != 0 && !skip_culled_mixed_pass(c, i);
    }
    id<MTLBuffer> facing = genuine && hasOutput ?
                               [self encodePolygonFacing:vertices
                                                   first:first
                                                   count:count
                                               clockwise:c->frontClockwise
                                                commands:commands
                                         indexedVertices:indexed
                                                   error:error] :
                               nil;
    if (genuine && hasOutput && !facing)
        return nil;
    NSMutableArray<NV2AMetalGeometryResult *> *result = [NSMutableArray new];
    for (unsigned i = 0; i < modes; i++) {
        if (skip_culled_mixed_pass(c, i))
            continue;
        NV2AMetalGeometryRasterConfig pass = *c;
        pass.front = pass.back = i ? c->back : c->front;
        pass.cullFront = c->cullFront || (modes == 2 && i);
        pass.cullBack = c->cullBack || (modes == 2 && !i);
        if (pass.front == NV2AMetalPolygonFill && c->polygonSmooth) {
            NV2AMetalGeometryResult *g =
                [self encodeCompactPolygonFill:vertices
                                         first:first
                                         count:count
                                     primitive:primitive
                                        config:&pass
                                        smooth:smooth
                                firstProvoking:firstProvoking
                                  zPerspective:zPerspective
                                      commands:commands
                               indexedVertices:indexed
                                 polygonFacing:facing
                                         error:error];
            if (!g)
                return nil;
            [result addObject:g];
        } else if (pass.front == NV2AMetalPolygonLine &&
                   (c->lineWidth > 1 || c->lineSmooth || zPerspective)) {
            NV2AMetalGeometryResult *g = [self encodeCompactLines:vertices
                                                            first:first
                                                            count:count
                                                        primitive:primitive
                                                           config:&pass
                                                           smooth:smooth
                                                   firstProvoking:firstProvoking
                                                     zPerspective:zPerspective
                                                         commands:commands
                                                  indexedVertices:indexed
                                                    polygonFacing:facing
                                                            error:error];
            if (!g)
                return nil;
            [result addObject:g];
        } else {
            NSArray *part = [self encodeNativeRasterVertices:vertices
                                                       first:first
                                                       count:count
                                                   primitive:primitive
                                                      config:&pass
                                                      smooth:smooth
                                              firstProvoking:firstProvoking
                                                zPerspective:zPerspective
                                                    commands:commands
                                             indexedVertices:indexed
                                               polygonFacing:facing
                                                       error:error];
            if (!part)
                return nil;
            [result addObjectsFromArray:part];
        }
    }
    return result;
}
- (NSArray<NV2AMetalGeometryResult *> *)
    encodeNativeRasterVertices:(id<MTLBuffer>)vertices
                         count:(NSUInteger)count
                     primitive:(enum NV2AMetalPrimitive)primitive
                        config:(const NV2AMetalGeometryRasterConfig *)c
                        smooth:(BOOL)smooth
                firstProvoking:(BOOL)firstProvoking
                  zPerspective:(BOOL)zPerspective
                      commands:(NV2AMetalCommands *)commands
                         error:(NSError **)error
{
    return [self encodeNativeRasterVertices:vertices
                                      first:0
                                      count:count
                                  primitive:primitive
                                     config:c
                                     smooth:smooth
                             firstProvoking:firstProvoking
                               zPerspective:zPerspective
                                   commands:commands
                                      error:error];
}
- (NSArray<NV2AMetalGeometryResult *> *)
    encodeNativeRasterVertices:(id<MTLBuffer>)vertices
                         first:(NSUInteger)first
                         count:(NSUInteger)count
                     primitive:(enum NV2AMetalPrimitive)primitive
                        config:(const NV2AMetalGeometryRasterConfig *)c
                        smooth:(BOOL)smooth
                firstProvoking:(BOOL)firstProvoking
                  zPerspective:(BOOL)zPerspective
                      commands:(NV2AMetalCommands *)commands
                         error:(NSError **)error
{
    return [self encodeNativeRasterVertices:vertices first:first count:count
        primitive:primitive config:c smooth:smooth firstProvoking:firstProvoking
        zPerspective:zPerspective commands:commands indexedVertices:nil error:error];
}
- (NSArray<NV2AMetalGeometryResult *> *)
    encodeNativeRasterSlice:(NV2AMetalVertexSlice *)slice
                  primitive:(enum NV2AMetalPrimitive)primitive
                     config:(const NV2AMetalGeometryRasterConfig *)c
                     smooth:(BOOL)smooth
             firstProvoking:(BOOL)firstProvoking
               zPerspective:(BOOL)zPerspective
                   commands:(NV2AMetalCommands *)commands
               surfaceCache:(NV2AMetalSurfaceCache *)surfaceCache
               continuation:(NV2AMetalGeometryContinuation **)continuation
                      error:(NSError **)error
{
    if (continuation)
        *continuation = nil;
    NV2AMetalSurfaceRecording *recording = surfaceCache.recording;
    uint64_t serial = commands.recordingSerial;
    NSArray<NV2AMetalGeometryResult *> *results =
        [self encodeNativeRasterSlice:slice
                            primitive:primitive
                               config:c
                               smooth:smooth
                       firstProvoking:firstProvoking
                         zPerspective:zPerspective
                             commands:commands
                                error:error];
    if (!results || !continuation || !recording ||
        surfaceCache.commands != commands ||
        surfaceCache.recording != recording || recording.submitted ||
        recording.cancelled || !commands.commandBuffer ||
        commands.recordingSerial != serial)
        return results;
    BOOL compact = NO;
    for (NV2AMetalGeometryResult *result in results)
        compact |= result.vertexCount &&
                   (result.compactLines || result.compactPolygons);
    if (compact && [self canHandoffNativeRasterGeometry])
        *continuation =
            [[NV2AMetalGeometryContinuation alloc] initWithResults:results
                                                      surfaceCache:surfaceCache
                                                          commands:commands];
    return results;
}
- (BOOL)canHandoffNativeRasterGeometry
{
    return YES;
}
- (NSArray<NV2AMetalGeometryResult *> *)
    continueNativeRasterGeometry:(NV2AMetalGeometryContinuation *)continuation
                    surfaceCache:(NV2AMetalSurfaceCache *)surfaceCache
                        commands:(NV2AMetalCommands *)commands
{
    NV2AMetalSurfaceRecording *recording = surfaceCache.recording;
    uint64_t serial = commands.recordingSerial;
    if (continuation.class != NV2AMetalGeometryContinuation.class ||
        continuation.consumed || continuation.surfaceCache != surfaceCache ||
        continuation.commands != commands ||
        surfaceCache.commands != commands || !commands.commandBuffer ||
        !recording || recording.submitted || recording.cancelled ||
        recording == continuation.recording ||
        !continuation.recording.submitted || continuation.recording.cancelled ||
        serial <= continuation.serial ||
        continuation.original.count != continuation.items.count)
        return nil;
    for (NSUInteger i = 0; i < continuation.items.count; i++)
        if (continuation.original[i] != continuation.items[i] ||
            ![continuation.items[i]
                matchesContinuationResult:continuation.prepared[i]])
            return nil;
    /* Full submission owns the original uploads through feedback. Its queue
     * barriers and the next submission's event wait order these immutable
     * private outputs before their later raster reads. Pixel preparation pins
     * every source, remap and derived buffer again in the receiving slot.
     * Only unpublished, preallocated wrappers change their recording identity.
     */
    continuation.consumed = YES;
    for (NV2AMetalGeometryResult *result in continuation.prepared) {
        if (result.compactLines || result.compactPolygons) {
            result.coverageCommands = commands;
            result.coverageSerial = serial;
        }
    }
    return continuation.prepared;
}
- (NSArray<NV2AMetalGeometryResult *> *)
    encodeNativeRasterSlice:(NV2AMetalVertexSlice *)slice
                  primitive:(enum NV2AMetalPrimitive)primitive
                     config:(const NV2AMetalGeometryRasterConfig *)c
                     smooth:(BOOL)smooth
             firstProvoking:(BOOL)firstProvoking
               zPerspective:(BOOL)zPerspective
                   commands:(NV2AMetalCommands *)commands
                      error:(NSError **)error
{
    if (!slice) {
        geometry_error(error, @"Missing native geometry slice");
        return nil;
    }
    return [self encodeNativeRasterVertices:slice.buffer first:slice.firstVertex
        count:slice.vertexCount primitive:primitive config:c smooth:smooth
        firstProvoking:firstProvoking zPerspective:zPerspective commands:commands
        indexedVertices:slice.indexedVertices error:error];
}
- (NSArray<NV2AMetalGeometryResult *> *)
    encodeNativeRasterVertices:(id<MTLBuffer>)vertices
                         first:(NSUInteger)first
                         count:(NSUInteger)count
                     primitive:(enum NV2AMetalPrimitive)primitive
                        config:(const NV2AMetalGeometryRasterConfig *)c
                        smooth:(BOOL)smooth
                firstProvoking:(BOOL)firstProvoking
                  zPerspective:(BOOL)zPerspective
                      commands:(NV2AMetalCommands *)commands
               indexedVertices:(NV2AMetalIndexedVertices *)indexed
                         error:(NSError **)error
{
    return [self encodeNativeRasterVertices:vertices
                                      first:first
                                      count:count
                                  primitive:primitive
                                     config:c
                                     smooth:smooth
                             firstProvoking:firstProvoking
                               zPerspective:zPerspective
                                   commands:commands
                            indexedVertices:indexed
                              polygonFacing:nil
                                      error:error];
}
- (NSArray<NV2AMetalGeometryResult *> *)
    encodeNativeRasterVertices:(id<MTLBuffer>)vertices
                         first:(NSUInteger)first
                         count:(NSUInteger)count
                     primitive:(enum NV2AMetalPrimitive)primitive
                        config:(const NV2AMetalGeometryRasterConfig *)c
                        smooth:(BOOL)smooth
                firstProvoking:(BOOL)firstProvoking
                  zPerspective:(BOOL)zPerspective
                      commands:(NV2AMetalCommands *)commands
               indexedVertices:(NV2AMetalIndexedVertices *)indexed
                 polygonFacing:(id<MTLBuffer>)sharedFace
                         error:(NSError **)error
{
    /* Reject the complete logical/physical binding before a fallback can
     * allocate or encode a gather and replace the borrowed input buffer. */
    if (!valid_raster_config(c, error))
        return nil;
    if (!commands.commandBuffer || commands.device != _device ||
        vertices.device != _device || count > UINT32_MAX ||
        primitive < NV2AMetalPrimitivePoints ||
        primitive > NV2AMetalPrimitivePolygon ||
        (primitive == NV2AMetalPrimitivePolygon &&
         (c->front == NV2AMetalPolygonPoint ||
          c->back == NV2AMetalPolygonPoint)) ||
        (indexed &&
         (vertices != indexed.vertices || indexed.indices.device != _device ||
          indexed.physicalVertexCount >
              vertices.length / sizeof(NV2AMetalVertex))) ||
        first > (indexed ? indexed.vertexCount :
                           vertices.length / sizeof(NV2AMetalVertex)) ||
        count > (indexed ? indexed.vertexCount :
                           vertices.length / sizeof(NV2AMetalVertex)) -
                    first) {
        geometry_error(error,
                       @"Invalid Metal native primitive input or recording");
        return nil;
    }
    if (primitive >= NV2AMetalPrimitiveTriangles &&
        (((c->front == NV2AMetalPolygonLine || c->back == NV2AMetalPolygonLine) &&
          (c->lineWidth > 1 || c->lineSmooth || zPerspective)) ||
         ((c->front == NV2AMetalPolygonFill || c->back == NV2AMetalPolygonFill) &&
          c->polygonSmooth)))
        return [self encodeCompactPolygonRaster:vertices
                                          first:first
                                          count:count
                                      primitive:primitive
                                         config:c
                                         smooth:smooth
                                 firstProvoking:firstProvoking
                                   zPerspective:zPerspective
                                       commands:commands
                                indexedVertices:indexed
                                          error:error];
    if (primitive >= NV2AMetalPrimitiveLines &&
        primitive <= NV2AMetalPrimitiveLineStrip &&
        (c->lineWidth > 1 || c->lineSmooth || zPerspective)) {
        NV2AMetalGeometryResult *result =
            [self encodeCompactLines:vertices
                               first:first
                               count:count
                           primitive:primitive
                              config:c
                              smooth:smooth
                      firstProvoking:firstProvoking
                        zPerspective:zPerspective
                            commands:commands
                     indexedVertices:indexed
                               error:error];
        return result ? @[ result ] : nil;
    }
    if (primitive == NV2AMetalPrimitivePolygon &&
        direct_polygon_mode(c->front, c, zPerspective) &&
        direct_polygon_mode(c->back, c, zPerspective)) {
        unsigned modes = c->front == c->back ? 1 : 2;
        NSUInteger outputs[2], perPrimitive[2];
        BOOL hasOutput = NO;
        for (unsigned i = 0; i < modes; i++) {
            enum NV2AMetalPolygonMode mode = i ? c->back : c->front;
            perPrimitive[i] = mode == NV2AMetalPolygonFill ? 3 : 2;
            NSUInteger primitives = mode == NV2AMetalPolygonFill ?
                (count < 3 ? 0 : count - 2) : (count < 2 ? 0 : count);
            if (primitives > UINT32_MAX / perPrimitive[i]) {
                geometry_error(error, @"Native polygon exceeds vertex ID range");
                return nil;
            }
            outputs[i] = primitives * perPrimitive[i];
            hasOutput |= outputs[i] != 0 && !skip_culled_mixed_pass(c, i);
        }
        id<MTLBuffer> facing = !hasOutput ?
                                   nil :
                               sharedFace ?:
                                            [self encodePolygonFacing:vertices
                                                                first:first
                                                                count:count
                                                            clockwise:c->frontClockwise
                                                             commands:commands
                                                      indexedVertices:indexed
                                                                error:error];
        if (hasOutput && !facing)
            return nil;
        NSMutableArray *results = [NSMutableArray new];
        for (unsigned i = 0; i < modes; i++) {
            if (skip_culled_mixed_pass(c, i))
                continue;
            enum NV2AMetalPolygonMode mode = i ? c->back : c->front;
            BOOL fill = mode == NV2AMetalPolygonFill;
            NV2AMetalGeometryResult *result = [[NV2AMetalGeometryResult alloc]
                initWithVertices:outputs[i] ? vertices : nil count:outputs[i]
                type:fill ? MTLPrimitiveTypeTriangle : MTLPrimitiveTypeLine
                polygon:mode perPrimitive:perPrimitive[i] expandedLines:NO expandedPolygons:NO];
            result.sourceVertexCount = outputs[i] ? count : 0;
            result.physicalVertexCount = !outputs[i] ? 0 :
                indexed ? indexed.physicalVertexCount : count;
            result.firstVertex = outputs[i] && !indexed ? first : 0;
            result.indexOffset = outputs[i] && indexed ? first : 0;
            result.indexedVertices = outputs[i] ? indexed : nil;
            result.polygonFacing = outputs[i] ? facing : nil;
            unsigned options = NV2AMetalDirectTrianglePolygon |
                (smooth ? NV2AMetalDirectTriangleSmooth : 0) |
                (zPerspective ? NV2AMetalDirectTriangleWDepth : 0) |
                (c->frontClockwise ? NV2AMetalDirectTriangleClockwise : 0) |
                (c->cullFront || (modes == 2 && i) ? NV2AMetalDirectTriangleCullFront : 0) |
                (c->cullBack || (modes == 2 && !i) ? NV2AMetalDirectTriangleCullBack : 0);
            result.directTriangles = fill;
            if (fill)
                result.directTriangleOptions = options;
            else
                result.directPolygonOptions = options | NV2AMetalDirectPolygonLine;
            [results addObject:result];
        }
        return results;
    }
    BOOL points = primitive == NV2AMetalPrimitivePoints;
    BOOL polygonTopology = primitive >= NV2AMetalPrimitiveTriangles &&
                           primitive <= NV2AMetalPrimitiveQuadStrip;
    BOOL quadTopology = primitive == NV2AMetalPrimitiveQuads ||
                        primitive == NV2AMetalPrimitiveQuadStrip;
    if (polygonTopology && c->front != c->back &&
        direct_polygon_mode(c->front, c, zPerspective) &&
        direct_polygon_mode(c->back, c, zPerspective)) {
        /* Validate both generated spans before registering either borrowed
         * source. Every mode remains a complete result; the raster consumer
         * alternates their slices per primitive to preserve blend/stencil. */
        NSUInteger primitives = primitive == NV2AMetalPrimitiveTriangles ? count / 3 :
            primitive == NV2AMetalPrimitiveQuads ? count / 4 :
            primitive == NV2AMetalPrimitiveQuadStrip ? (count < 4 ? 0 : count / 2 - 1) :
            count < 3 ? 0 : count - 2;
        for (unsigned i = 0; i < 2; i++) {
            enum NV2AMetalPolygonMode mode = i ? c->back : c->front;
            NSUInteger per = mode == NV2AMetalPolygonFill ? (quadTopology ? 6 : 3) :
                mode == NV2AMetalPolygonPoint ? (quadTopology ? 4 : 3) :
                                               (quadTopology ? 8 : 6);
            if (primitives > UINT32_MAX / per) {
                geometry_error(error, @"Native geometry draw exceeds vertex ID range");
                return nil;
            }
        }
        NSMutableArray *results = [NSMutableArray new];
        for (unsigned i = 0; i < 2; i++) {
            if (skip_culled_mixed_pass(c, i))
                continue;
            NV2AMetalGeometryRasterConfig pass = *c;
            pass.front = pass.back = i ? c->back : c->front;
            pass.cullFront = c->cullFront || i;
            pass.cullBack = c->cullBack || !i;
            NSArray *result = [self encodeNativeRasterVertices:vertices first:first
                count:count primitive:primitive config:&pass smooth:smooth
                firstProvoking:firstProvoking zPerspective:zPerspective
                commands:commands indexedVertices:indexed error:error];
            if (!result)
                return nil;
            [results addObjectsFromArray:result];
        }
        return results;
    }
    BOOL lines = primitive >= NV2AMetalPrimitiveLines &&
                 primitive <= NV2AMetalPrimitiveLineStrip && c &&
                 c->lineWidth <= 1 && !c->lineSmooth && !zPerspective;
    BOOL triangles = primitive >= NV2AMetalPrimitiveTriangles &&
                     primitive <= NV2AMetalPrimitiveQuadStrip && c &&
                     c->front == NV2AMetalPolygonFill &&
                     c->back == NV2AMetalPolygonFill && !c->polygonSmooth;
    BOOL quadPoints = quadTopology && c->front == NV2AMetalPolygonPoint &&
                      c->back == NV2AMetalPolygonPoint;
    BOOL quadLines = quadTopology && c->front == NV2AMetalPolygonLine &&
                     c->back == NV2AMetalPolygonLine && c->lineWidth <= 1 &&
                     !c->lineSmooth && !zPerspective;
    BOOL directQuad = quadPoints || quadLines;
    BOOL triangleTopology = polygonTopology && !quadTopology;
    BOOL polygonPoints = triangleTopology && c->front == NV2AMetalPolygonPoint &&
                         c->back == NV2AMetalPolygonPoint;
    BOOL polygonLines = triangleTopology && c->front == NV2AMetalPolygonLine &&
                        c->back == NV2AMetalPolygonLine &&
                        direct_polygon_mode(NV2AMetalPolygonLine, c, zPerspective);
    BOOL directPolygon = polygonPoints || polygonLines;
    if (!points && !lines && !triangles && !directQuad && !directPolygon) {
        if (indexed) {
            NV2AMetalVertexStream *stream = [[NV2AMetalVertexStream alloc]
                initWithDevice:_device limit:count error:error];
            if (!stream || ![stream appendIndexedVertices:indexed first:first
                count:count error:error])
                return nil;
            vertices = [stream encodeWithCommands:commands error:error];
            if (!vertices && count)
                return nil;
            first = 0;
        }
        if (sharedFace)
            return [self encodeRasterVertices:vertices
                                        first:first
                                        count:count
                                    primitive:primitive
                                       config:c
                                       smooth:smooth
                               firstProvoking:firstProvoking
                                 zPerspective:zPerspective
                                     commands:commands
                                polygonFacing:sharedFace
                                        error:error];
        return [self encodeRasterVertices:vertices
                                    first:first
                                    count:count
                                primitive:primitive
                                   config:c
                                   smooth:smooth
                           firstProvoking:firstProvoking
                             zPerspective:zPerspective
                                 commands:commands
                                    error:error];
    }
    BOOL quads = quadTopology && (triangles || directQuad);
    NSUInteger perPrimitive = quadPoints ? 4 : quadLines ? 8 : polygonLines ? 6 :
                              points ? 1 : lines ? 2 : quads ? 6 : 3;
    BOOL mappedTriangles = (triangles || directPolygon) && primitive != NV2AMetalPrimitiveTriangles;
    BOOL mappedLines = lines && primitive != NV2AMetalPrimitiveLines;
    NSUInteger primitives = mappedLines ? (count < 2 ? 0 :
                                count - (primitive == NV2AMetalPrimitiveLineStrip)) :
                            quads ? (primitive == NV2AMetalPrimitiveQuads ? count / 4 :
                                         count < 4 ? 0 : count / 2 - 1) :
                            mappedTriangles ? (count < 3 ? 0 : count - 2) :
                            directPolygon ? count / 3 :
                                             count / perPrimitive;
    if (primitives > UINT32_MAX / perPrimitive) {
        geometry_error(error, @"Native geometry draw exceeds vertex ID range");
        return nil;
    }
    NSUInteger outputCount = primitives * perPrimitive;
    if (outputCount && ![commands addResource:vertices error:error])
        return nil;
    /* Direct graphics functions supply the metadata that the compute case
     * would otherwise copy out. Ignore an incomplete final primitive. */
    NV2AMetalGeometryResult *result = [[NV2AMetalGeometryResult alloc]
        initWithVertices:outputCount ? vertices : nil
                   count:outputCount
                    type:points || quadPoints || polygonPoints ? MTLPrimitiveTypePoint :
                         lines || quadLines || polygonLines ? MTLPrimitiveTypeLine :
                                              MTLPrimitiveTypeTriangle
                 polygon:directQuad || directPolygon ? c->front : NV2AMetalPolygonFill
            perPrimitive:perPrimitive
           expandedLines:NO
        expandedPolygons:NO];
    result.firstVertex = outputCount && !indexed ? first : 0;
    result.indexedVertices = outputCount ? indexed : nil;
    result.indexOffset = outputCount && indexed ? first : 0;
    if (outputCount && indexed &&
        (![commands addResource:indexed.indices error:error] ||
         ![commands keepAlive:indexed error:error]))
        return nil;
    if (mappedTriangles || mappedLines || directQuad || directPolygon)
        result.sourceVertexCount = !outputCount ? 0 :
            primitive == NV2AMetalPrimitiveQuads ? count / 4 * 4 :
            primitive == NV2AMetalPrimitiveQuadStrip ? count / 2 * 2 : count;
    if (directPolygon && primitive == NV2AMetalPrimitiveTriangles)
        result.sourceVertexCount = count / 3 * 3;
    result.physicalVertexCount = !outputCount ? 0 :
        indexed ? indexed.physicalVertexCount : result.sourceVertexCount;
    result.directPoints = points;
    result.directTriangles = triangles;
    if (triangles || directQuad || directPolygon) {
        unsigned options =
            (smooth ? NV2AMetalDirectTriangleSmooth : 0) |
            (firstProvoking && !quads ? NV2AMetalDirectTriangleFirst : 0) |
            (zPerspective ? NV2AMetalDirectTriangleWDepth : 0) |
            (c->frontClockwise ? NV2AMetalDirectTriangleClockwise : 0) |
            (c->cullFront ? NV2AMetalDirectTriangleCullFront : 0) |
            (c->cullBack ? NV2AMetalDirectTriangleCullBack : 0) |
            (primitive == NV2AMetalPrimitiveTriangleStrip ? NV2AMetalDirectTriangleStrip : 0) |
            (primitive == NV2AMetalPrimitiveTriangleFan ? NV2AMetalDirectTriangleFan : 0) |
            (primitive == NV2AMetalPrimitiveQuads ? NV2AMetalDirectTriangleQuads : 0) |
            (primitive == NV2AMetalPrimitiveQuadStrip ? NV2AMetalDirectTriangleQuadStrip : 0);
        if (directPolygon)
            result.directPolygonOptions = options |
                (polygonPoints ? NV2AMetalDirectPolygonPoint : NV2AMetalDirectPolygonLine);
        else if (directQuad)
            result.directQuadOptions = options |
                (quadPoints ? NV2AMetalDirectQuadPoint : NV2AMetalDirectQuadLine);
        else
            result.directTriangleOptions = options;
    }
    if (lines) {
        result.directLineMode = smooth ? NV2AMetalGeometryDirectLineSmooth :
                                firstProvoking ?
                                         NV2AMetalGeometryDirectLineFlatFirst :
                                         NV2AMetalGeometryDirectLineFlatLast;
        result.directLineOptions =
            (smooth ? NV2AMetalDirectLineSmooth :
                 firstProvoking ? NV2AMetalDirectLineFirst : 0) |
            (primitive == NV2AMetalPrimitiveLineStrip ? NV2AMetalDirectLineStrip : 0) |
            (primitive == NV2AMetalPrimitiveLineLoop ? NV2AMetalDirectLineLoop : 0);
    }
    return @[ result ];
}
- (NSArray<NV2AMetalGeometryResult *> *)
    encodeRasterVertices:(id<MTLBuffer>)vertices
                   count:(NSUInteger)count
               primitive:(enum NV2AMetalPrimitive)primitive
                  config:(const NV2AMetalGeometryRasterConfig *)c
                  smooth:(BOOL)smooth
          firstProvoking:(BOOL)firstProvoking
            zPerspective:(BOOL)zPerspective
                commands:(NV2AMetalCommands *)commands
                   error:(NSError **)error
{
    return [self encodeRasterVertices:vertices
                                first:0
                                count:count
                            primitive:primitive
                               config:c
                               smooth:smooth
                       firstProvoking:firstProvoking
                         zPerspective:zPerspective
                             commands:commands
                                error:error];
}
- (NSArray<NV2AMetalGeometryResult *> *)
    encodeRasterVertices:(id<MTLBuffer>)vertices
                   first:(NSUInteger)first
                   count:(NSUInteger)count
               primitive:(enum NV2AMetalPrimitive)primitive
                  config:(const NV2AMetalGeometryRasterConfig *)c
                  smooth:(BOOL)smooth
          firstProvoking:(BOOL)firstProvoking
            zPerspective:(BOOL)zPerspective
                commands:(NV2AMetalCommands *)commands
                   error:(NSError **)error
{
    return [self encodeRasterVertices:vertices
                                first:first
                                count:count
                            primitive:primitive
                               config:c
                               smooth:smooth
                       firstProvoking:firstProvoking
                         zPerspective:zPerspective
                             commands:commands
                        polygonFacing:nil
                                error:error];
}
- (NSArray<NV2AMetalGeometryResult *> *)
    encodeRasterVertices:(id<MTLBuffer>)vertices
                   first:(NSUInteger)first
                   count:(NSUInteger)count
               primitive:(enum NV2AMetalPrimitive)primitive
                  config:(const NV2AMetalGeometryRasterConfig *)c
                  smooth:(BOOL)smooth
          firstProvoking:(BOOL)firstProvoking
            zPerspective:(BOOL)zPerspective
                commands:(NV2AMetalCommands *)commands
           polygonFacing:(id<MTLBuffer>)sharedFace
                   error:(NSError **)error
{
    if (!valid_raster_config(c, error))
        return nil;
    NSMutableArray<NV2AMetalGeometryResult *> *result = [NSMutableArray new];
    BOOL polygon = primitive >= NV2AMetalPrimitiveTriangles;
    unsigned modes = polygon && c->front != c->back ? 2 : 1;
    for (unsigned i = 0; i < modes; i++) {
        if (polygon && skip_culled_mixed_pass(c, i))
            continue;
        unsigned faceMask = 0;
        enum NV2AMetalPolygonMode mode =
            polygon ? (i ? c->back : c->front) : NV2AMetalPolygonFill;
        if (polygon) {
            faceMask = (c->cullFront ? 0 : 1) | (c->cullBack ? 0 : 2);
            if (modes == 2)
                faceMask &= i ? 2 : 1;
            faceMask = faceMask == 3 ? 0 : faceMask ? faceMask : 4;
        }
        NV2AMetalGeometryResult *g =
            [self encodeVertices:vertices
                           first:first
                           count:count
                       primitive:primitive
                         polygon:mode
                          smooth:smooth
                  firstProvoking:firstProvoking
                    zPerspective:zPerspective
                        faceMask:faceMask
                  frontClockwise:c->frontClockwise
                       lineWidth:c->lineWidth ? c->lineWidth : 1
                      lineSmooth:c->lineSmooth
                   polygonSmooth:c->polygonSmooth
                   viewportWidth:c->viewportWidth
                  viewportHeight:c->viewportHeight
                        commands:commands
                   polygonFacing:sharedFace
                           error:error];
        if (!g)
            return nil;
        [result addObject:g];
    }
    return result;
}
- (nullable NV2AMetalGeometryResult *)
    encodeVertices:(id<MTLBuffer>)vertices
             first:(NSUInteger)first
             count:(NSUInteger)count
         primitive:(enum NV2AMetalPrimitive)primitive
           polygon:(enum NV2AMetalPolygonMode)polygon
            smooth:(BOOL)smooth
    firstProvoking:(BOOL)firstProvoking
      zPerspective:(BOOL)zPerspective
          faceMask:(unsigned)faceMask
    frontClockwise:(BOOL)frontClockwise
         lineWidth:(float)lineWidth
        lineSmooth:(BOOL)lineSmooth
     polygonSmooth:(BOOL)polygonSmooth
     viewportWidth:(NSUInteger)viewportWidth
    viewportHeight:(NSUInteger)viewportHeight
          commands:(NV2AMetalCommands *)commands
             error:(NSError **)error
{
    return [self encodeVertices:vertices
                          first:first
                          count:count
                      primitive:primitive
                        polygon:polygon
                         smooth:smooth
                 firstProvoking:firstProvoking
                   zPerspective:zPerspective
                       faceMask:faceMask
                 frontClockwise:frontClockwise
                      lineWidth:lineWidth
                     lineSmooth:lineSmooth
                  polygonSmooth:polygonSmooth
                  viewportWidth:viewportWidth
                 viewportHeight:viewportHeight
                       commands:commands
                  polygonFacing:nil
                          error:error];
}
- (nullable NV2AMetalGeometryResult *)
    encodeVertices:(id<MTLBuffer>)vertices
             first:(NSUInteger)first
             count:(NSUInteger)count
         primitive:(enum NV2AMetalPrimitive)primitive
           polygon:(enum NV2AMetalPolygonMode)polygon
            smooth:(BOOL)smooth
    firstProvoking:(BOOL)firstProvoking
      zPerspective:(BOOL)zPerspective
          faceMask:(unsigned)faceMask
    frontClockwise:(BOOL)frontClockwise
         lineWidth:(float)lineWidth
        lineSmooth:(BOOL)lineSmooth
     polygonSmooth:(BOOL)polygonSmooth
     viewportWidth:(NSUInteger)viewportWidth
    viewportHeight:(NSUInteger)viewportHeight
          commands:(NV2AMetalCommands *)commands
     polygonFacing:(id<MTLBuffer>)sharedFace
             error:(NSError **)error
{
    if (!commands.commandBuffer || commands.device != _device ||
        vertices.device != _device || count > UINT32_MAX ||
        first > vertices.length / sizeof(NV2AMetalVertex) ||
        count > vertices.length / sizeof(NV2AMetalVertex) - first ||
        primitive < NV2AMetalPrimitivePoints ||
        primitive > NV2AMetalPrimitivePolygon ||
        polygon < NV2AMetalPolygonFill || polygon > NV2AMetalPolygonLine ||
        (primitive == NV2AMetalPrimitivePolygon &&
         polygon == NV2AMetalPolygonPoint) ||
        (sharedFace && (primitive != NV2AMetalPrimitivePolygon ||
                        sharedFace.device != _device ||
                        sharedFace.length != sizeof(uint32_t) ||
                        sharedFace.storageMode != MTLStorageModePrivate))) {
        geometry_error(error, @"Invalid Metal geometry input or recording");
        return nil;
    }
    NSUInteger primitives = 0, perPrimitive = 0;
    MTLPrimitiveType type;
    switch (primitive) {
    case NV2AMetalPrimitivePoints:
        primitives = count;
        perPrimitive = 1;
        type = MTLPrimitiveTypePoint;
        break;
    case NV2AMetalPrimitiveLines:
    case NV2AMetalPrimitiveLineLoop:
    case NV2AMetalPrimitiveLineStrip:
        primitives =
            primitive == NV2AMetalPrimitiveLines ? count / 2 :
            count < 2                            ? 0 :
                        count - (primitive == NV2AMetalPrimitiveLineStrip);
        perPrimitive = 2;
        type = MTLPrimitiveTypeLine;
        break;
    default: {
        BOOL quad = primitive == NV2AMetalPrimitiveQuads ||
                    primitive == NV2AMetalPrimitiveQuadStrip;
        if (primitive == NV2AMetalPrimitiveTriangles) {
            primitives = count / 3;
        } else if (primitive == NV2AMetalPrimitiveQuads) {
            primitives = count / 4;
        } else if (primitive == NV2AMetalPrimitiveQuadStrip) {
            primitives = count < 4 ? 0 : count / 2 - 1;
        } else if (primitive == NV2AMetalPrimitivePolygon &&
                   polygon == NV2AMetalPolygonLine) {
            primitives = count < 2 ? 0 : count;
        } else {
            primitives = count < 3 ? 0 : count - 2;
        }
        type = polygon == NV2AMetalPolygonFill  ? MTLPrimitiveTypeTriangle :
               polygon == NV2AMetalPolygonPoint ? MTLPrimitiveTypePoint :
                                                  MTLPrimitiveTypeLine;
        perPrimitive = polygon == NV2AMetalPolygonFill  ? (quad ? 6 : 3) :
                       polygon == NV2AMetalPolygonPoint ? (quad ? 4 : 3) :
                                                          (quad ? 8 : 6);
        if (primitive == NV2AMetalPrimitivePolygon &&
            polygon == NV2AMetalPolygonLine) {
            perPrimitive = 2;
        }
        break;
    }
    }
    BOOL expandedLines = type == MTLPrimitiveTypeLine &&
                         (lineWidth > 1 || lineSmooth || zPerspective);
    if (expandedLines && (!viewportWidth || !viewportHeight ||
                          viewportWidth > 16384 || viewportHeight > 16384)) {
        geometry_error(error, @"Expanded lines require a valid viewport");
        return nil;
    }
    BOOL expandedPolygons = type == MTLPrimitiveTypeTriangle && polygonSmooth;
    if (expandedPolygons)
        perPrimitive *= 2;
    if (expandedLines) {
        perPrimitive *= 3;
        type = MTLPrimitiveTypeTriangle;
    }
    if (primitives > UINT32_MAX / perPrimitive ||
        primitives >
            _device.maxBufferLength / sizeof(NV2AMetalVertex) / perPrimitive) {
        geometry_error(error, @"Metal geometry expansion is too large");
        return nil;
    }
    NSUInteger outputCount = primitives * perPrimitive;
    if (!outputCount) {
        return
            [[NV2AMetalGeometryResult alloc] initWithVertices:nil
                                                        count:0
                                                         type:type
                                                      polygon:polygon
                                                 perPrimitive:perPrimitive
                                                expandedLines:expandedLines
                                             expandedPolygons:expandedPolygons];
    }
    /* Direct and empty draws never need the expansion shader. Polygons
     * alone need the additional facing dispatch. */
    if (!_module) {
        _module = [NV2AMetalShaderLibrary sharedWithDevice:_device
                                                   source:metal_shader_source
                                                    error:error];
        if (!_module)
            return nil;
    }
    if (!_pipeline) {
        _pipeline = [_module computeFunction:@"nv2a_expand_geometry" error:error];
        if (!_pipeline)
            return nil;
    }
    BOOL polygonFace = primitive == NV2AMetalPrimitivePolygon;
    if (polygonFace && !sharedFace && !_polygonFacing) {
        _polygonFacing = [_module computeFunction:@"nv2a_polygon_face" error:error];
        if (!_polygonFacing)
            return nil;
    }
    id<MTLBuffer> output =
        [_device newBufferWithLength:outputCount * sizeof(NV2AMetalVertex)
                             options:MTLResourceStorageModeShared];
    id<MTLBuffer> projections =
        expandedPolygons ?
            [_device newBufferWithLength:outputCount / 6 *
                                         sizeof(NV2AMetalPolygonProjection)
                                 options:MTLResourceStorageModePrivate] :
            _emptyProjections;
    if (!projections) {
        geometry_error(error, @"Could not allocate polygon projections");
        return nil;
    }
    NV2AMetalGeometryUniforms uniforms = { primitive,
                                           polygon,
                                           smooth,
                                           firstProvoking,
                                           zPerspective,
                                           (unsigned)count,
                                           (unsigned)primitives,
                                           (unsigned)perPrimitive,
                                           faceMask,
                                           frontClockwise,
                                           { (float)viewportWidth,
                                             (float)viewportHeight },
                                           lineWidth,
                                           lineSmooth,
                                           polygonSmooth };
    NSUInteger constantsOffset = 0;
    id<MTLBuffer> constants = [commands uploadBytes:&uniforms
                                             length:sizeof(uniforms)
                                             offset:&constantsOffset
                                              error:error];
    if (!constants) {
        return nil;
    }
    if (!output) {
        geometry_error(error, @"Could not allocate Metal geometry output");
        return nil;
    }
    id<MTLBuffer> facing =
        polygonFace ?
            sharedFace ?:
                         [_device newBufferWithLength:4
                                              options:MTLResourceStorageModeShared] :
            constants;
    if (!facing) {
        geometry_error(error, @"Could not allocate polygon face result");
        return nil;
    }
    if (![commands addResource:vertices error:error] ||
        ![commands addResource:output error:error] ||
        ![commands addResource:projections error:error] ||
        (polygonFace && ![commands addResource:facing error:error]) ||
        ![commands keepAlive:self error:error]) {
        return nil;
    }
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        geometry_error(error, @"Could not create Metal geometry encoder");
        return nil;
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageDispatch
                   visibilityOptions:MTL4VisibilityOptionDevice];
    if (polygonFace && !sharedFace) {
        [_arguments
            setAddress:vertices.gpuAddress + first * sizeof(NV2AMetalVertex)
               atIndex:0];
        [_arguments setAddress:facing.gpuAddress atIndex:1];
        [_arguments setAddress:constants.gpuAddress + constantsOffset
                       atIndex:2];
        [_arguments setAddress:constants.gpuAddress + constantsOffset
                       atIndex:3];
        [encoder setArgumentTable:_arguments];
        [encoder setComputePipelineState:_polygonFacing];
        [encoder dispatchThreads:MTLSizeMake(1, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [encoder barrierAfterEncoderStages:MTLStageDispatch
                       beforeEncoderStages:MTLStageDispatch
                         visibilityOptions:MTL4VisibilityOptionDevice];
    }
    [_arguments setAddress:vertices.gpuAddress + first * sizeof(NV2AMetalVertex)
                   atIndex:0];
    [_arguments setAddress:output.gpuAddress atIndex:1];
    [_arguments setAddress:constants.gpuAddress + constantsOffset atIndex:2];
    [_arguments
        setAddress:facing.gpuAddress + (polygonFace ? 0 : constantsOffset)
           atIndex:3];
    [_arguments setAddress:projections.gpuAddress atIndex:4];
    [encoder setArgumentTable:_arguments];
    [encoder setComputePipelineState:_pipeline];
    NSUInteger width = _pipeline.threadExecutionWidth;
    if (width > primitives) {
        width = primitives;
    }
    [encoder dispatchThreads:MTLSizeMake(primitives, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
    [encoder barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    NV2AMetalGeometryResult *result =
        [[NV2AMetalGeometryResult alloc] initWithVertices:output
                                                    count:outputCount
                                                     type:type
                                                  polygon:polygon
                                             perPrimitive:perPrimitive
                                            expandedLines:expandedLines
                                         expandedPolygons:expandedPolygons];
    result.polygonProjections = expandedPolygons ? projections : nil;
    return result;
}
@end
