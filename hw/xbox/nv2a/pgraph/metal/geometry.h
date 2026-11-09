/* SPDX-License-Identifier: LGPL-2.0-or-later */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_GEOMETRY_H
#define HW_XBOX_NV2A_PGRAPH_METAL_GEOMETRY_H

#import "command.h"
#include "geometry-types.h"

@class NV2AMetalVertexSlice, NV2AMetalIndexedVertices, NV2AMetalSurfaceCache;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(unsigned, NV2AMetalGeometryDirectLineMode) {
    NV2AMetalGeometryDirectLineNone,
    NV2AMetalGeometryDirectLineSmooth,
    NV2AMetalGeometryDirectLineFlatFirst,
    NV2AMetalGeometryDirectLineFlatLast,
};

API_AVAILABLE(macos(26.0))
@interface NV2AMetalGeometryResult : NSObject
@property(nonatomic, readonly, nullable) id<MTLBuffer> vertices;
@property(nonatomic, readonly) NSUInteger vertexCount;
/* Bound source span, which can be smaller than the generated draw. */
@property(nonatomic, readonly) NSUInteger sourceVertexCount;
/* Indexed direct draws retain the immutable physical source and logical map. */
@property(nonatomic, readonly, nullable) NV2AMetalIndexedVertices *indexedVertices;
@property(nonatomic, readonly) NSUInteger physicalVertexCount, indexOffset;
/* First source vertex for borrowed input. Generated draw IDs stay relative
 * to that bound source; materialized compute outputs use zero. */
@property(nonatomic, readonly) NSUInteger firstVertex;
@property(nonatomic, readonly) MTLPrimitiveType primitiveType;
@property(nonatomic, readonly) enum NV2AMetalPolygonMode polygonMode;
@property(nonatomic, readonly) NSUInteger primitiveCount, verticesPerPrimitive;
@property(nonatomic, readonly) BOOL expandedLines;
/* Six generated carrier corners per private 128-byte packet. Original source
 * vertices remain borrowed; this derived packet belongs to its recording. */
@property(nonatomic, readonly) BOOL compactLines;
/* Original topology for compact carriers; zero for other result kinds. */
@property(nonatomic, readonly) enum NV2AMetalPrimitive sourcePrimitive;
@property(nonatomic, readonly, nullable) id<MTLBuffer> lineCoverage;
- (BOOL)canUseLineCoverageForCommands:(NV2AMetalCommands *)commands;
/* Smooth fill borrows its original attributes through one private carrier
 * per generated triangle, together with the unchanged projection records. */
@property(nonatomic, readonly) BOOL compactPolygons;
@property(nonatomic, readonly, nullable) id<MTLBuffer> polygonCoverage;
- (BOOL)canUsePolygonCoverageForCommands:(NV2AMetalCommands *)commands;
@property(nonatomic, readonly) BOOL expandedPolygons;
/* One immutable GPU record per six-vertex polygon transport. No CPU readback.
 * Bind together with vertices, including the corresponding slice offset. */
@property(nonatomic, readonly, nullable) id<MTLBuffer> polygonProjections;
/* Genuine direct polygons share one GPU uint: 0 back, 1 front. This is never
 * CPU-read and remains bound at the same address for every generated slice. */
@property(nonatomic, readonly, nullable) id<MTLBuffer> polygonFacing;
/* Bind these vertices with NV2AMetalPixelRasterDirectPoint. */
@property(nonatomic, readonly) BOOL directPoints;
/* Bind with DirectTriangle | directTriangleOptions in the pixel stage. */
@property(nonatomic, readonly) BOOL directTriangles;
@property(nonatomic, readonly) unsigned directTriangleOptions;
/* Quad point/wire source mapping. Bind DirectTriangle | directQuadOptions;
 * true point/line/fill markers above and below remain unset for these modes. */
@property(nonatomic, readonly) unsigned directQuadOptions;
/* Triangle-list/strip/fan point/wire mapping, or genuine polygon wire. Bind
 * DirectTriangle OR these options; triangle counts are 3 points/6 endpoints,
 * while genuine polygon wire generates 2 endpoints per boundary edge. */
@property(nonatomic, readonly) unsigned directPolygonOptions;
/* Nonzero requires the matching direct-line pixel raster class. */
@property(nonatomic, readonly) NV2AMetalGeometryDirectLineMode directLineMode;
/* Nonzero topology bits select DirectMappedLine | directLineOptions. */
@property(nonatomic, readonly) unsigned directLineOptions;
@end

/* One optional handoff of immutable native geometry after its exact producing
 * surface recording was submitted. Only the geometry encoder can create it;
 * cancellation, foreign owners and unsubmitted sections cannot be continued. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalGeometryContinuation : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

typedef struct NV2AMetalGeometryRasterConfig {
    enum NV2AMetalPolygonMode front, back;
    BOOL frontClockwise, cullFront, cullBack;
    /* Zero width preserves default 1. Wide/smooth lines expand on GPU with
     * a physical viewport; the fragment shader evaluates their GL coverage. */
    float lineWidth;
    BOOL lineSmooth;
    BOOL polygonSmooth;
    NSUInteger viewportWidth, viewportHeight;
} NV2AMetalGeometryRasterConfig;

/* Replaces glsl/geom.c's geometry stage with native Metal 4 compute. Input is
 * an assembled logical stream after vertex processing. Native raster slices
 * can preserve an immutable indexed source; other paths materialize it before
 * compute expansion. Batch carryover is assembled by the draw frontend.
 * Like the GL implementation, PRIM_POLYGON point mode is unsupported. Raster
 * capture can select front/back modes and cull polygons before line/point
 * emission, while direct point/line primitives ignore polygon culling. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalGeometry : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (nullable NV2AMetalGeometryResult *)
    encodeVertices:(id<MTLBuffer>)vertices
             count:(NSUInteger)count
         primitive:(enum NV2AMetalPrimitive)primitive
           polygon:(enum NV2AMetalPolygonMode)polygon
            smooth:(BOOL)smooth
    firstProvoking:(BOOL)firstProvoking
      zPerspective:(BOOL)zPerspective
          commands:(NV2AMetalCommands *)commands
             error:(NSError *_Nullable *_Nullable)error;
/* Graphics-ready paths borrow the source for true points, thin unsmoothed
 * non-W lines, unsmoothed triangle/quad fill, and triangle/quad points and thin
 * wire. Mapped vertexCount is the generated draw count; the direct vertex
 * shader maps it back to source vertices. Line strips/loops likewise generate
 * endpoint pairs from the bound source. Wide, smooth or W-depth true lines and
 * polygon wire use private 128-byte compact carriers while retaining the
 * borrowed vertices/remap. Smooth polygon fill uses one compact carrier and
 * its unchanged projection per generated triangle. Face, flat provoker and
 * depth slope retain the compute path's semantics.
 * Mixed modes return complete mode streams. Draw each original primitive's front/back slices in
 * input order. Genuine polygons use whole-polygon facing and draw each mode
 * as a whole stream. The original API below continues to return fully
 * materialized vertex records for its callers. */
- (nullable NSArray<NV2AMetalGeometryResult *> *)
    encodeNativeRasterSlice:(NV2AMetalVertexSlice *)slice
                  primitive:(enum NV2AMetalPrimitive)primitive
                     config:(const NV2AMetalGeometryRasterConfig *_Nullable)config
                     smooth:(BOOL)smooth
             firstProvoking:(BOOL)firstProvoking
               zPerspective:(BOOL)zPerspective
                   commands:(NV2AMetalCommands *)commands
                      error:(NSError *_Nullable *_Nullable)error;
/* Executes the complete original encoder before creating optional metadata.
 * A nil continuation preserves the original recording-bound rebuild path. */
- (nullable NSArray<NV2AMetalGeometryResult *> *)
    encodeNativeRasterSlice:(NV2AMetalVertexSlice *)slice
                  primitive:(enum NV2AMetalPrimitive)primitive
                     config:
                         (const NV2AMetalGeometryRasterConfig *_Nullable)config
                     smooth:(BOOL)smooth
             firstProvoking:(BOOL)firstProvoking
               zPerspective:(BOOL)zPerspective
                   commands:(NV2AMetalCommands *)commands
               surfaceCache:(NV2AMetalSurfaceCache *)surfaceCache
               continuation:
                   (NV2AMetalGeometryContinuation *_Nullable *_Nullable)
                       continuation
                      error:(NSError *_Nullable *_Nullable)error;
/* No allocation, encoding, wait or feedback publication. Success consumes the
 * ticket once and returns fresh, strictly recording-bound result wrappers.
 * Nil means the caller must retain its original full rebuild path. */
- (nullable NSArray<NV2AMetalGeometryResult *> *)
    continueNativeRasterGeometry:(NV2AMetalGeometryContinuation *)continuation
                    surfaceCache:(NV2AMetalSurfaceCache *)surfaceCache
                        commands:(NV2AMetalCommands *)commands;
- (nullable NSArray<NV2AMetalGeometryResult *> *)
    encodeNativeRasterVertices:(id<MTLBuffer>)vertices
                         count:(NSUInteger)count
                     primitive:(enum NV2AMetalPrimitive)primitive
                        config:(const NV2AMetalGeometryRasterConfig *_Nullable)config
                        smooth:(BOOL)smooth
                firstProvoking:(BOOL)firstProvoking
                  zPerspective:(BOOL)zPerspective
                      commands:(NV2AMetalCommands *)commands
                         error:(NSError *_Nullable *_Nullable)error;
/* Same graphics-ready path, consuming only [first,first+count) of the source.
 * Compute expansion binds that source offset; direct results preserve it. */
- (nullable NSArray<NV2AMetalGeometryResult *> *)
    encodeNativeRasterVertices:(id<MTLBuffer>)vertices
                         first:(NSUInteger)first
                         count:(NSUInteger)count
                     primitive:(enum NV2AMetalPrimitive)primitive
                        config:(const NV2AMetalGeometryRasterConfig *_Nullable)
                                   config
                        smooth:(BOOL)smooth
                firstProvoking:(BOOL)firstProvoking
                  zPerspective:(BOOL)zPerspective
                      commands:(NV2AMetalCommands *)commands
                         error:(NSError *_Nullable *_Nullable)error;
/* Returns one mode stream, or two GPU-filtered streams for mixed face modes.
 * For mixed modes the caller must draw each original primitive's slices in
 * input order, not all front faces followed by all back faces. PRIM_POLYGON
 * is one polygon; its mode streams can each be drawn as a whole. Filtered
 * slots are fully clipped, so no CPU face/vertex readback is necessary. */
- (nullable NSArray<NV2AMetalGeometryResult *> *)
    encodeRasterVertices:(id<MTLBuffer>)vertices
                   count:(NSUInteger)count
               primitive:(enum NV2AMetalPrimitive)primitive
                  config:(const NV2AMetalGeometryRasterConfig *_Nullable)config
                  smooth:(BOOL)smooth
          firstProvoking:(BOOL)firstProvoking
            zPerspective:(BOOL)zPerspective
                commands:(NV2AMetalCommands *)commands
                   error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
#endif
