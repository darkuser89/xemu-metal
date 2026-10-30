/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_PGRAPH_H
#define HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_PGRAPH_H
#import "vertex-fixed.h"
#import "vertex-program.h"
typedef struct PGRAPHState PGRAPHState;
@class NV2AMetalValidatedProgram;

NS_ASSUME_NONNULL_BEGIN
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPGRAPHVertexResult : NSObject
@property(nonatomic, readonly, nullable) id<MTLBuffer> vertices, registers;
@property(nonatomic, readonly) NSUInteger vertexCount;
@property(nonatomic, readonly) BOOL programmed;
/* The draw frontend must inspect each NV2AMetalProgramOutput.fault after GPU
 * completion, before drawing a program with relative constants or ARL.
 * These flags are validation failures, not invented NV2A hardware results. */
@end

/* Immutable register/constant/program snapshot, constructed with pg.lock held
 * after surfaces have been prepared. Array fetch and batch carryover are the
 * draw frontend's responsibility. No dirty flags or live PGRAPH state mutate.
 * Uniform getters return copies; programBytes is immutable owned data.
 * The existing GL fixed-function and programmable limits remain explicit. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPGRAPHVertexState : NSObject
@property(nonatomic, readonly) BOOL fullAccess, writeEnable, rasterDiscard;
@property(nonatomic, readonly) BOOL programmed, dynamicAddressing, smooth,
    zPerspective;
/* Cached proof for this capture's access policy and immutable constants.
 * Only permits queued execution when actual context writes are disabled. */
@property(nonatomic, readonly) BOOL faultFreeReadOnlyAccess;
@property(nonatomic, readonly) uint16_t compressedAttributes, uniformAttributes,
    swizzleAttributes;
@property(nonatomic, readonly) NV2AMetalProgramInput inlineValues;
@property(nonatomic, readonly) NV2AMetalProgramUniforms programUniforms;
@property(nonatomic, readonly) NV2AMetalFixedUniforms fixedUniforms;
@property(nonatomic, readonly) NSData *programBytes;
/* In-memory validated instructions; never serialized into snapshotData. */
@property(nonatomic, readonly, nullable)
    NV2AMetalValidatedProgram *validatedProgram;
- (nullable instancetype)initWithState:(PGRAPHState *)state
                                 error:(NSError *_Nullable *_Nullable)error;
/* XF-only execution may precede any raster attachment. Derive missing bound
 * dimensions from the declared surface shape without binding or mutating it.
 * This retains the same program/fixed decoder and immutable capture format. */
- (nullable instancetype)
    initForTransformOnlyWithState:(PGRAPHState *)state
                            error:(NSError *_Nullable *_Nullable)error;
/* Explicit program-only capture for XF context work. No raster metadata is
 * consumed. The caller must not send this capture to geometry/raster work. */
- (nullable instancetype)initRawProgramWithState:(PGRAPHState *)state
                                           error:(NSError *_Nullable *_Nullable)
                                                     error;
/* Explicit fixed or programmed XF-only capture. Raster-only surface metadata
 * is omitted; fixed lighting/texgen/fog/point metadata remains captured. */
- (nullable instancetype)initRawXFWithState:(PGRAPHState *)state
                                      error:
                                          (NSError *_Nullable *_Nullable)error;
/* Versioned big-endian words, without GPU resources or host pointers. */
- (NSData *)snapshotData;
- (nullable instancetype)initWithSnapshot:(NSData *)data
                                    error:(NSError *_Nullable *_Nullable)error;
/* Clone only GPU-marked constants, preserving the captured policy and wire
 * version. Does not modify live PGRAPH or dirty flags. */
- (nullable NV2AMetalPGRAPHVertexState *)
    stateByApplyingConstants:(NSData *)constants
                     written:(NSData *)written
                       error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
/* Compatibility encoder for full-access/read-only programmable captures,
 * and fixed function. Stateful policies require NV2AMetalEpochExecutor. */
- (nullable NV2AMetalPGRAPHVertexResult *)
    encodeAttributes:(id<MTLBuffer>)attributes
               count:(NSUInteger)count
             program:(nullable NV2AMetalVertexProgram *)program
               fixed:(nullable NV2AMetalVertexFixed *)fixed
            commands:(NV2AMetalCommands *)commands
               error:(NSError *_Nullable *_Nullable)error;
@end
NS_ASSUME_NONNULL_END
#endif
