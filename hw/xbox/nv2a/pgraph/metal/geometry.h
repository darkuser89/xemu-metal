/* SPDX-License-Identifier: LGPL-2.0-or-later */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_GEOMETRY_H
#define HW_XBOX_NV2A_PGRAPH_METAL_GEOMETRY_H

#import "command.h"
#include "geometry-types.h"

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
/* Nonzero for a borrowed direct-graphics input slice. All counts/primitive
 * slices are relative to this vertex. Materialized compute outputs use zero. */
@property(nonatomic, readonly) NSUInteger firstVertex;
@property(nonatomic, readonly) MTLPrimitiveType primitiveType;
@property(nonatomic, readonly) enum NV2AMetalPolygonMode polygonMode;
@property(nonatomic, readonly) NSUInteger primitiveCount, verticesPerPrimitive;
@property(nonatomic, readonly) BOOL expandedLines;
@property(nonatomic, readonly) BOOL expandedPolygons;
/* One immutable GPU record per six-vertex polygon transport. No CPU readback.
 * Bind together with vertices, including the corresponding slice offset. */
@property(nonatomic, readonly, nullable) id<MTLBuffer> polygonProjections;
/* Bind these vertices with NV2AMetalPixelRasterDirectPoint. */
@property(nonatomic, readonly) BOOL directPoints;
/* Bind with DirectTriangle | directTriangleOptions in the pixel stage. */
@property(nonatomic, readonly) BOOL directTriangles;
@property(nonatomic, readonly) unsigned directTriangleOptions;
/* Nonzero requires the matching direct-line pixel raster class. */
@property(nonatomic, readonly) NV2AMetalGeometryDirectLineMode directLineMode;
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
 * an assembled, non-indexed stream after vertex processing. Indexed draws and
 * batch carryover must be resolved by the draw frontend before this stage.
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
/* Graphics-ready path: true points, thin unsmoothed non-W line lists, and
 * unsmoothed triangle lists with both polygon modes set to fill reuse the
 * input buffer. Their matching direct vertex shaders supply the metadata.
 * Other primitives retain full compute expansion. The original API below
 * continues to return fully materialized vertex records for its callers. */
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
