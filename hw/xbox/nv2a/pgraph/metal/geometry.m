/* SPDX-License-Identifier: LGPL-2.0-or-later */

#import "geometry.h"
#include "geometry-source.h"
#include <stdint.h>
#include <stddef.h>
#include <math.h>

_Static_assert(sizeof(NV2AMetalPolygonProjection) == 68,
               "CPU/MSL polygon projection");
_Static_assert(sizeof(NV2AMetalVertex) == 244, "CPU/MSL vertex layout");
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

@interface NV2AMetalGeometryResult ()
@property(nonatomic, readwrite, strong, nullable) id<MTLBuffer>
    polygonProjections;
@property(nonatomic, readwrite) NSUInteger firstVertex;
@property(nonatomic, readwrite) BOOL directPoints;
@property(nonatomic, readwrite) BOOL directTriangles;
@property(nonatomic, readwrite) unsigned directTriangleOptions;
@property(nonatomic, readwrite) NV2AMetalGeometryDirectLineMode directLineMode;
@end

@implementation NV2AMetalGeometryResult
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
        _primitiveType = type;
        _polygonMode = polygon;
        _verticesPerPrimitive = perPrimitive;
        _primitiveCount = perPrimitive ? count / perPrimitive : 0;
        _expandedLines = expandedLines;
        _expandedPolygons = expandedPolygons;
    }
    return self;
}
@end

@implementation NV2AMetalGeometry {
    id<MTLDevice> _device;
    id<MTLComputePipelineState> _pipeline, _polygonFacing;
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
    id<MTL4Compiler> compiler =
        [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                    error:error];
    if (!compiler) {
        return nil;
    }
    MTL4LibraryDescriptor *libraryDescriptor = [MTL4LibraryDescriptor new];
    libraryDescriptor.source = @(metal_shader_source);
    libraryDescriptor.options = [MTLCompileOptions new];
    libraryDescriptor.options.languageVersion = MTLLanguageVersion4_0;
    libraryDescriptor.options.mathMode = MTLMathModeSafe;
    libraryDescriptor.options.mathFloatingPointFunctions =
        MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> library =
        [compiler newLibraryWithDescriptor:libraryDescriptor error:error];
    if (!library) {
        return nil;
    }
    MTL4LibraryFunctionDescriptor *function =
        [MTL4LibraryFunctionDescriptor new];
    function.library = library;
    function.name = @"nv2a_expand_geometry";
    MTL4ComputePipelineDescriptor *descriptor =
        [MTL4ComputePipelineDescriptor new];
    descriptor.computeFunctionDescriptor = function;
    _pipeline = [compiler newComputePipelineStateWithDescriptor:descriptor
                                            compilerTaskOptions:nil
                                                          error:error];
    if (!_pipeline) {
        return nil;
    }
    function.name = @"nv2a_polygon_face";
    descriptor.computeFunctionDescriptor = function;
    _polygonFacing = [compiler newComputePipelineStateWithDescriptor:descriptor
                                                 compilerTaskOptions:nil
                                                               error:error];
    if (!_polygonFacing)
        return nil;
    MTL4ArgumentTableDescriptor *arguments = [MTL4ArgumentTableDescriptor new];
    arguments.maxBufferBindCount = 5;
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
    BOOL points = primitive == NV2AMetalPrimitivePoints;
    BOOL lines = primitive == NV2AMetalPrimitiveLines && c &&
                 c->lineWidth <= 1 && !c->lineSmooth && !zPerspective;
    BOOL triangles = primitive == NV2AMetalPrimitiveTriangles && c &&
                     c->front == NV2AMetalPolygonFill &&
                     c->back == NV2AMetalPolygonFill && !c->polygonSmooth;
    if (!points && !lines && !triangles)
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
    if (!valid_raster_config(c, error))
        return nil;
    if (!commands.commandBuffer || commands.device != _device ||
        vertices.device != _device || count > UINT32_MAX ||
        first > vertices.length / sizeof(NV2AMetalVertex) ||
        count > vertices.length / sizeof(NV2AMetalVertex) - first) {
        geometry_error(error,
                       @"Invalid Metal native primitive input or recording");
        return nil;
    }
    NSUInteger perPrimitive = points ? 1 : lines ? 2 : 3;
    NSUInteger outputCount = count / perPrimitive * perPrimitive;
    if (outputCount && ![commands addResource:vertices error:error])
        return nil;
    /* Direct graphics functions supply the metadata that the compute case
     * would otherwise copy out. Ignore an incomplete final primitive. */
    NV2AMetalGeometryResult *result = [[NV2AMetalGeometryResult alloc]
        initWithVertices:outputCount ? vertices : nil
                   count:outputCount
                    type:points ? MTLPrimitiveTypePoint :
                         lines  ? MTLPrimitiveTypeLine :
                                  MTLPrimitiveTypeTriangle
                 polygon:NV2AMetalPolygonFill
            perPrimitive:perPrimitive
           expandedLines:NO
        expandedPolygons:NO];
    result.firstVertex = outputCount ? first : 0;
    result.directPoints = points;
    result.directTriangles = triangles;
    if (triangles)
        result.directTriangleOptions =
            (smooth ? NV2AMetalDirectTriangleSmooth : 0) |
            (firstProvoking ? NV2AMetalDirectTriangleFirst : 0) |
            (zPerspective ? NV2AMetalDirectTriangleWDepth : 0) |
            (c->frontClockwise ? NV2AMetalDirectTriangleClockwise : 0) |
            (c->cullFront ? NV2AMetalDirectTriangleCullFront : 0) |
            (c->cullBack ? NV2AMetalDirectTriangleCullBack : 0);
    if (lines)
        result.directLineMode = smooth ? NV2AMetalGeometryDirectLineSmooth :
                                firstProvoking ?
                                         NV2AMetalGeometryDirectLineFlatFirst :
                                         NV2AMetalGeometryDirectLineFlatLast;
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
    if (!valid_raster_config(c, error))
        return nil;
    NSMutableArray<NV2AMetalGeometryResult *> *result = [NSMutableArray new];
    BOOL polygon = primitive >= NV2AMetalPrimitiveTriangles;
    unsigned modes = polygon && c->front != c->back ? 2 : 1;
    for (unsigned i = 0; i < modes; i++) {
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
    if (!commands.commandBuffer || commands.device != _device ||
        vertices.device != _device || count > UINT32_MAX ||
        first > vertices.length / sizeof(NV2AMetalVertex) ||
        count > vertices.length / sizeof(NV2AMetalVertex) - first ||
        primitive < NV2AMetalPrimitivePoints ||
        primitive > NV2AMetalPrimitivePolygon ||
        polygon < NV2AMetalPolygonFill || polygon > NV2AMetalPolygonLine ||
        (primitive == NV2AMetalPrimitivePolygon &&
         polygon == NV2AMetalPolygonPoint)) {
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
    BOOL polygonFace = primitive == NV2AMetalPrimitivePolygon;
    id<MTLBuffer> facing =
        polygonFace ?
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
    if (polygonFace) {
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
