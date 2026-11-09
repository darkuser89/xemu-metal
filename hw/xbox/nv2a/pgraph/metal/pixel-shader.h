/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_PIXEL_SHADER_H
#define HW_XBOX_NV2A_PGRAPH_METAL_PIXEL_SHADER_H

#import "command.h"
#import "draw-state.h"
#include "pixel-shader-types.h"
#import "geometry.h"
#import "lru-cache.h"

@class NV2AMetalPipelineCompiler;

NS_ASSUME_NONNULL_BEGIN

/* Shared CPU validation for register capture and the native render encoder. */
BOOL nv2a_metal_pixel_validate(const NV2AMetalPixelUniforms *_Nullable uniforms,
                               NSError *_Nullable *_Nullable error);

/* Borrowed until encodeVertices returns; the command slot then retains the
 * sampled resources and samplers until GPU completion. */
typedef struct NV2AMetalPixelTexture {
    __unsafe_unretained id<MTLTexture> _Nullable texture;
    __unsafe_unretained id<MTLSamplerState> _Nullable sampler;
} NV2AMetalPixelTexture;

/* This pipeline uses conventional vertex/fragment work, including visibility
 * results and attachment stores/resolves. Use this on the pass side of BOTH
 * queue barriers. A borrowed pass must not contain object/mesh/tile commands.
 */
API_AVAILABLE(macos(26.0))
static inline MTLStages nv2a_metal_pixel_pass_stages(void)
{
    return MTLStageVertex | MTLStageFragment;
}

/* Native raster pipeline consuming expanded NV2AMetalVertex data. The caller
 * owns PGRAPH state capture, surfaces, texture conversion/cache and draw
 * batching. BRDF and floating-depth approximations remain incomplete hardware
 * implementations. Color targets
 * support R8/RG8/RGBA8/BGRA8, B5G6R5/BGR5A1 and RGBA32Float; depth targets
 * support Depth16Unorm, Depth32Float and Depth32Float_Stencil8. Invalid color
 * format selects a depth/stencil-only pass with viewport taken from depth.
 * At least one attachment format must be valid. The surface
 * layer must select NV2A formats and handle VRAM packing/channel policy. */
typedef NS_ENUM(unsigned, NV2AMetalPixelRasterClass) {
    NV2AMetalPixelRasterDynamic,
    NV2AMetalPixelRasterNative,
    NV2AMetalPixelRasterExpandedLine,
    NV2AMetalPixelRasterExpandedPolygon,
    /* Unexpanded point records; vertex stage supplies plane/front metadata. */
    NV2AMetalPixelRasterDirectPoint,
    NV2AMetalPixelRasterDirectLineSmooth,
    NV2AMetalPixelRasterDirectLineFlatFirst,
    NV2AMetalPixelRasterDirectLineFlatLast,
    /* Geometry-owned compact carriers at buffer6 plus borrowed source0;
     * sourcePrimitive distinguishes real lines and polygon boundary groups. */
    NV2AMetalPixelRasterCompactLine,
    /* Geometry-owned smooth-polygon carriers and unchanged projections. */
    NV2AMetalPixelRasterCompactPolygon,
    /* OR with NV2AMetalDirectTriangleOptions for the vertex specialization.
     * Counts describe generated triangle corners, or quad point/wire corners
     * with DirectQuadPoint/Line (4/8 per quad). Triangle strips/fans bind
     * count/3+2 sources, filled quad lists count/6*4 and strips count/3+2.
     * Quad point/wire lists bind 4 sources per quad, strips 2 per quad + 2;
     * DirectPolygonPoint/Line generate 3/6 records per triangle. Triangle
     * lists bind 3 sources per triangle, strips/fans 1 per triangle + 2;
     * genuine Polygon fill binds count/3+2 sources and wire count/2. Their
     * geometry-owned whole-polygon face is additionally bound at buffer 5;
     * empty draws bind zero sources. */
    NV2AMetalPixelRasterDirectTriangle = 0x100,
    /* OR with NV2AMetalDirectLineOptions. Counts are generated endpoints;
     * strips bind count/2+1 sources, loops count/2, empty draws zero. */
    NV2AMetalPixelRasterDirectMappedLine = 0x200,
};

/* Immutable host preparation for one raster slice. All validation, pipeline
 * creation, uploads and residency happen before the render encoder opens.
 * A packet belongs to exactly one live command recording. The caller keeps
 * the supplied pass descriptor unchanged and uses it for the whole group;
 * no producer, submit or cancel may intervene while emitting that group. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPixelDraw : NSObject
@property(nonatomic, readonly) NSUInteger vertexCount;
- (BOOL)encodeWithRenderEncoder:(id<MTL4RenderCommandEncoder>)encoder
                       commands:(NV2AMetalCommands *)commands
                          error:(NSError *_Nullable *_Nullable)error;
/* Emit a bounded range without changing this packet or preparing bindings
 * again. firstVertex is relative to its prepared span. Nonempty ranges must
 * cover complete geometry groups (raw packets use independent primitives);
 * raw strip packets permit only their complete span. Existing whole-packet
 * emission preserves the preparation API's partial-slice contract. */
- (BOOL)encodeWithRenderEncoder:(id<MTL4RenderCommandEncoder>)encoder
                       commands:(NV2AMetalCommands *)commands
                    firstVertex:(NSUInteger)first
                    vertexCount:(NSUInteger)count
                          error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

API_AVAILABLE(macos(26.0))
@interface NV2AMetalPixelShader : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            colorFormat:(MTLPixelFormat)colorFormat
                            depthFormat:(MTLPixelFormat)depthFormat
                            sampleCount:(NSUInteger)sampleCount
                                  error:(NSError *_Nullable *_Nullable)error;
/* Guest storage policy from NV2AMetalSurfaceStorage. B8/G8B8 remap B to native
 * R; X formats force their Z/O bits after blending, logic and dithering.
 * A7 normalizes its low seven alpha bits for blending and stores a forced
 * high bit. Native retains the attachment's component order and alpha
 * semantics. */
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            colorFormat:(MTLPixelFormat)colorFormat
                            depthFormat:(MTLPixelFormat)depthFormat
                            sampleCount:(NSUInteger)sampleCount
                        surfaceChannels:(unsigned int)surfaceChannels
                                  error:(NSError *_Nullable *_Nullable)error;
/* Render pipelines may be shared on the same encoding thread, device and
 * library for matching color format, sample count and attachment policy
 * (native, B8, G8B8 or packed alpha). Each instance validates its own depth
 * attachment, supplies its exact channel layout and owns its bindings. */
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            colorFormat:(MTLPixelFormat)colorFormat
                            depthFormat:(MTLPixelFormat)depthFormat
                            sampleCount:(NSUInteger)sampleCount
                        surfaceChannels:(unsigned int)surfaceChannels
                          pipelineCache:(nullable NV2AMetalLRUCache<
                              NSData *, id<MTLRenderPipelineState>> *)cache
                                  error:(NSError *_Nullable *_Nullable)error;
/* Only the PGRAPH controller opts into provisional generic pipelines.
 * nil preserves synchronous low-level construction and preparation. */
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            colorFormat:(MTLPixelFormat)colorFormat
                            depthFormat:(MTLPixelFormat)depthFormat
                            sampleCount:(NSUInteger)sampleCount
                        surfaceChannels:(unsigned int)surfaceChannels
                          pipelineCache:(nullable NV2AMetalLRUCache<
                              NSData *, id<MTLRenderPipelineState>> *)cache
                       pipelineCompiler:(nullable NV2AMetalPipelineCompiler *)compiler
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/* pass supplies level-zero 2D color/depth attachments and load/store/clear
 * actions, including an optional multisample color resolve. A visibility
 * buffer enables native counting at offset zero, with the supplied reset/
 * accumulate policy; its resource is retained until GPU completion.
 * Depth/stencil resolves and additional color attachments are unsupported. This
 * convenience entry uses caller-supplied depth/stencil testing, all color
 * channels and disabled blending. The drawState entry captures native raster
 * state and caches its pipelines. Texture coordinates use NV2A logical row0 at
 * Metal row0. A nil sampler selects nearest/clamp-to-edge. Converted depth
 * textures carry depth in R, a 24-bit flag in G and a floating flag in B.
 * F24 is physical depth; fixed depths and F16 use normalized depth. */
- (BOOL)encodeVertices:(id<MTLBuffer>)vertices
                 count:(NSUInteger)count
             primitive:(MTLPrimitiveType)primitive
              uniforms:(const NV2AMetalPixelUniforms *)uniforms
              textures:(const NV2AMetalPixelTexture *)textures
                  pass:(MTL4RenderPassDescriptor *)pass
          depthStencil:(nullable id<MTLDepthStencilState>)depthStencil
              commands:(NV2AMetalCommands *)commands
                 error:(NSError *_Nullable *_Nullable)error;
/* Native register-derived state, including blend/masks, depth/stencil,
 * culling/winding and clipped scissor. State and pipelines live until GPU
 * completion; unsupported states are rejected before opening an encoder. */
- (BOOL)encodeVertices:(id<MTLBuffer>)vertices
                 count:(NSUInteger)count
             primitive:(MTLPrimitiveType)primitive
              uniforms:(const NV2AMetalPixelUniforms *)uniforms
              textures:(const NV2AMetalPixelTexture *)textures
                  pass:(MTL4RenderPassDescriptor *)pass
             drawState:(NV2AMetalDrawState *)drawState
              commands:(NV2AMetalCommands *)commands
                 error:(NSError *_Nullable *_Nullable)error;
/* A slice starting at a whole vertex, measured in bytes, preserves order when
 * front and back faces emit different topologies. Bounds are checked against
 * the retained original buffer; vertex IDs start at zero within the slice. */
- (BOOL)encodeVertices:(id<MTLBuffer>)vertices
                offset:(NSUInteger)offset
                 count:(NSUInteger)count
             primitive:(MTLPrimitiveType)primitive
              uniforms:(const NV2AMetalPixelUniforms *)uniforms
              textures:(const NV2AMetalPixelTexture *)textures
                  pass:(MTL4RenderPassDescriptor *)pass
             drawState:(NV2AMetalDrawState *)drawState
              commands:(NV2AMetalCommands *)commands
                 error:(NSError *_Nullable *_Nullable)error;
- (BOOL)encodeVertices:(id<MTLBuffer>)vertices
                  offset:(NSUInteger)offset
                   count:(NSUInteger)count
               primitive:(MTLPrimitiveType)primitive
                uniforms:(const NV2AMetalPixelUniforms *)uniforms
                textures:(const NV2AMetalPixelTexture *)textures
                    pass:(MTL4RenderPassDescriptor *)pass
               drawState:(NV2AMetalDrawState *)drawState
    ignorePolygonCulling:(BOOL)ignore
                commands:(NV2AMetalCommands *)commands
                   error:(NSError *_Nullable *_Nullable)error;
/* Geometry-produced homogeneous raster class; Dynamic preserves the public
 * per-vertex tag path. The caller must prove the class for the whole slice. */
- (BOOL)encodeVertices:(id<MTLBuffer>)vertices
                  offset:(NSUInteger)offset
                   count:(NSUInteger)count
               primitive:(MTLPrimitiveType)primitive
                uniforms:(const NV2AMetalPixelUniforms *)uniforms
                textures:(const NV2AMetalPixelTexture *)textures
                    pass:(MTL4RenderPassDescriptor *)pass
               drawState:(NV2AMetalDrawState *)drawState
             rasterClass:(NV2AMetalPixelRasterClass)rasterClass
    ignorePolygonCulling:(BOOL)ignore
                commands:(NV2AMetalCommands *)commands
                   error:(NSError *_Nullable *_Nullable)error;
/* Encode into the caller's open render pass, or nil for a standalone pass.
 * The caller must use exactly this descriptor/command recording, keep the
 * descriptor immutable, and bracket the whole group with queue barriers using
 * nv2a_metal_pixel_pass_stages on the render-pass side and All on the queue
 * side (or a conservatively broader render-pass mask).
 * No compute, blit, clear, submission or cancellation may intervene. End the
 * encoder on success AND failure before crossing any such boundary. Load,
 * store, resolve and visibility reset apply once to the whole group. The
 * caller configures visibility mode/offset once when opening that encoder;
 * reselecting the same visibility offset within a pass is invalid in Metal4. */
- (BOOL)encodeVertices:(id<MTLBuffer>)vertices
                  offset:(NSUInteger)offset
                   count:(NSUInteger)count
               primitive:(MTLPrimitiveType)primitive
                uniforms:(const NV2AMetalPixelUniforms *)uniforms
                textures:(const NV2AMetalPixelTexture *)textures
                    pass:(MTL4RenderPassDescriptor *)pass
               drawState:(NV2AMetalDrawState *)drawState
             rasterClass:(NV2AMetalPixelRasterClass)rasterClass
    ignorePolygonCulling:(BOOL)ignore
           renderEncoder:(nullable id<MTL4RenderCommandEncoder>)renderEncoder
                commands:(NV2AMetalCommands *)commands
                   error:(NSError *_Nullable *_Nullable)error;
/* Prepare every slice before opening a shared render pass. The returned
 * packet snapshots all bindings, uniforms, raster state and the pipeline;
 * later preparation cannot change a previously prepared slice. Count zero
 * validates its inputs and returns a packet that emits no GPU work. */
- (nullable NV2AMetalPixelDraw *)
         prepareGeometry:(NV2AMetalGeometryResult *)geometry
                  offset:(NSUInteger)offset
                   count:(NSUInteger)count
                uniforms:(const NV2AMetalPixelUniforms *)uniforms
                textures:(const NV2AMetalPixelTexture *)textures
                    pass:(MTL4RenderPassDescriptor *)pass
               drawState:(NV2AMetalDrawState *)drawState
             rasterClass:(NV2AMetalPixelRasterClass)rasterClass
    ignorePolygonCulling:(BOOL)ignore
                commands:(NV2AMetalCommands *)commands
                   error:(NSError *_Nullable *_Nullable)error;
/* Scope the common attachment and texture checks to one immutable descriptor and
 * recording. End preparation before changing the descriptor or encoding. */
- (void)beginPreparationForPass:(MTL4RenderPassDescriptor *)pass
                         commands:(NV2AMetalCommands *)commands;
- (void)endPreparation;
/* Scope encoder state reuse to consecutive packets from this shader. End
 * the scope before other commands can change the encoder's state. */
- (void)beginRasterEncoding:(id<MTL4RenderCommandEncoder>)encoder;
- (void)endRasterEncoding;
/* Geometry-owned vertices/projections form one immutable binding. Slice offsets
 * address generated vertices; direct strips/fans keep their full source bound
 * and select the slice with draw IDs. Expanded polygons reuse the projection. */
- (BOOL)encodeGeometry:(NV2AMetalGeometryResult *)geometry
                  offset:(NSUInteger)offset
                   count:(NSUInteger)count
                uniforms:(const NV2AMetalPixelUniforms *)uniforms
                textures:(const NV2AMetalPixelTexture *)textures
                    pass:(MTL4RenderPassDescriptor *)pass
               drawState:(NV2AMetalDrawState *)drawState
             rasterClass:(NV2AMetalPixelRasterClass)rasterClass
    ignorePolygonCulling:(BOOL)ignore
           renderEncoder:(nullable id<MTL4RenderCommandEncoder>)renderEncoder
                commands:(NV2AMetalCommands *)commands
                   error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
#endif
