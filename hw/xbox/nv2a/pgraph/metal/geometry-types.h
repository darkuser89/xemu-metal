/* SPDX-License-Identifier: LGPL-2.0-or-later */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_GEOMETRY_TYPES_H
#define HW_XBOX_NV2A_PGRAPH_METAL_GEOMETRY_TYPES_H

/* Internal topology values follow ShaderPrimitiveMode/ShaderPolygonMode in
 * pgraph/vsh_regs.h. These are not hardware register definitions. */
enum NV2AMetalPrimitive {
    NV2AMetalPrimitivePoints = 1,
    NV2AMetalPrimitiveLines,
    NV2AMetalPrimitiveLineLoop,
    NV2AMetalPrimitiveLineStrip,
    NV2AMetalPrimitiveTriangles,
    NV2AMetalPrimitiveTriangleStrip,
    NV2AMetalPrimitiveTriangleFan,
    NV2AMetalPrimitiveQuads,
    NV2AMetalPrimitiveQuadStrip,
    NV2AMetalPrimitivePolygon,
};

enum NV2AMetalPolygonMode {
    NV2AMetalPolygonFill,
    NV2AMetalPolygonPoint,
    NV2AMetalPolygonLine,
};

enum NV2AMetalFace {
    NV2AMetalFaceNative,
    NV2AMetalFaceFront,
    NV2AMetalFaceBack,
};

/* Internal direct-polygon vertex specialization, not NV2A registers. */
enum NV2AMetalDirectTriangleOptions {
    NV2AMetalDirectTriangleSmooth = 1u << 0,
    NV2AMetalDirectTriangleFirst = 1u << 1,
    NV2AMetalDirectTriangleWDepth = 1u << 2,
    NV2AMetalDirectTriangleClockwise = 1u << 3,
    NV2AMetalDirectTriangleCullFront = 1u << 4,
    NV2AMetalDirectTriangleCullBack = 1u << 5,
    NV2AMetalDirectTriangleStrip = 1u << 6,
    NV2AMetalDirectTriangleFan = 2u << 6,
    NV2AMetalDirectTriangleQuads = 3u << 6,
    NV2AMetalDirectTriangleQuadStrip = 1u << 10,
    NV2AMetalDirectTrianglePolygon = 1u << 15,
    NV2AMetalDirectTriangleTopologyMask = (3u << 6) | (1u << 10) | (1u << 15),
    /* Quad-only point/wire modes share the source/topology specialization. */
    NV2AMetalDirectQuadPoint = 1u << 11,
    NV2AMetalDirectQuadLine = 1u << 12,
    NV2AMetalDirectQuadModeMask = (1u << 11) | (1u << 12),
    /* Triangle lists/strips/fans retain their triangle plane and provoker. */
    NV2AMetalDirectPolygonPoint = 1u << 13,
    NV2AMetalDirectPolygonLine = 1u << 14,
    NV2AMetalDirectPolygonModeMask = (1u << 13) | (1u << 14),
    NV2AMetalDirectTriangleMask = ((1u << 8) - 1) | (1u << 10) |
                                  NV2AMetalDirectQuadModeMask |
                                  NV2AMetalDirectPolygonModeMask | (1u << 15),
};

/* Internal thin-line vertex specialization, not NV2A registers. */
enum NV2AMetalDirectLineOptions {
    NV2AMetalDirectLineSmooth = 1u << 0,
    NV2AMetalDirectLineFirst = 1u << 1,
    NV2AMetalDirectLineStrip = 1u << 2,
    NV2AMetalDirectLineLoop = 2u << 2,
    NV2AMetalDirectLineTopologyMask = 3u << 2,
    NV2AMetalDirectLineMask = (1u << 4) - 1,
};

/* GPU-only projection shared by geometry and coverage fragments. Scalar
 * arrays preserve the host/MSL layout without enlarging every vertex. */
typedef struct NV2AMetalPolygonProjection {
    float points[8][2];
    unsigned int count;
} NV2AMetalPolygonProjection;

/* GPU-only line carrier. Original attributes stay in the borrowed source;
 * indices are physical ordinals relative to its bound vertex-buffer base. */
typedef struct NV2AMetalCompactLine {
    float clip[4][2];
    float p0[4], p1[4], p2[4];
    float slope, width;
    unsigned int smooth, face;
    unsigned int source[2], provoking, color_smooth, valid;
    unsigned int reserved[3];
} NV2AMetalCompactLine;

/* Filled polygon carrier. Six generated corners borrow three original
 * attributes; the projection record retains the unchanged coverage polygon. */
typedef struct NV2AMetalCompactPolygon {
    float clip[4][2];
    float p0[4], p1[4], p2[4];
    float slope;
    unsigned int face, valid, color_smooth;
    unsigned int source[3], provoking;
    float viewport[2];
    unsigned int reserved[2];
} NV2AMetalCompactPolygon;

/* Scalar arrays keep the CPU and MSL layouts identical. The vertex stage must
 * supply native Metal clip coordinates and the original NV2A screen position.
 * Only color[] follows flat shading; fog and texture coordinates remain smooth.
 * plane[] and slope are generated here for later fragment interpolation. */
typedef struct NV2AMetalVertex {
    float clip[4];
    float color[4][4];
    float texcoord[4][4];
    float screen[4];
    float fog;
    float point_size;
    /* Filled polygon coverage transport retains original clip XY here. */
    float coverage_clip[2];
    float plane[3][4];
    float slope;
    /* Transport kind in [2]: 1 line (width, smooth), 2 filled polygon
     * (original clip W, viewport width; viewport height in point_size).
     * Otherwise zero. Original attributes remain at slots 0/2/5. */
    float line_raster[3];
    /* Original polygon face survives line/point/coverage expansion. Zero
     * allows direct triangle draws to use Metal's front_facing input. */
    unsigned int face;
} NV2AMetalVertex;

typedef struct NV2AMetalGeometryUniforms {
    unsigned int primitive;
    unsigned int polygon;
    unsigned int smooth;
    unsigned int first_provoking;
    unsigned int z_perspective;
    unsigned int input_count;
    unsigned int primitive_count;
    unsigned int output_per_primitive;
    /* Internal face filter: 0 all, bit0 front, bit1 back, 4 neither. */
    unsigned int face_mask;
    unsigned int front_clockwise;
    float viewport[2];
    float line_width;
    unsigned int line_smooth;
    unsigned int polygon_smooth;
} NV2AMetalGeometryUniforms;

#endif
