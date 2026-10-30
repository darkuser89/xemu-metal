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

/* Internal direct-triangle pipeline specialization, not NV2A registers. */
enum NV2AMetalDirectTriangleOptions {
    NV2AMetalDirectTriangleSmooth = 1u << 0,
    NV2AMetalDirectTriangleFirst = 1u << 1,
    NV2AMetalDirectTriangleWDepth = 1u << 2,
    NV2AMetalDirectTriangleClockwise = 1u << 3,
    NV2AMetalDirectTriangleCullFront = 1u << 4,
    NV2AMetalDirectTriangleCullBack = 1u << 5,
    NV2AMetalDirectTriangleMask = (1u << 6) - 1,
};

/* GPU-only projection shared by geometry and coverage fragments. Scalar
 * arrays preserve the host/MSL layout without enlarging every vertex. */
typedef struct NV2AMetalPolygonProjection {
    float points[8][2];
    unsigned int count;
} NV2AMetalPolygonProjection;

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
