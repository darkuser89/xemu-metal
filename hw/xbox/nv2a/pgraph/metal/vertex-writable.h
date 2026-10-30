/* Native serial vertex programs with XFCTX side effects.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_WRITABLE_H
#define HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_WRITABLE_H

#import "command.h"
#include "vertex-program-types.h"
#include "geometry-types.h"
NS_ASSUME_NONNULL_BEGIN
/* Device-independent immutable decoder output. Only raw token constructors
 * may create it; portable snapshots still contain raw tokens, never this data.
 */
__attribute__((objc_subclassing_restricted))
@interface NV2AMetalValidatedProgram : NSObject
@property(nonatomic, readonly) NSData *tokens, *instructions;
@property(nonatomic, readonly) NSUInteger slots;
/* Conservative effect of executable slots through END, independent of the
 * guest write-enable flag. Only an active masked constant destination counts.
 */
@property(nonatomic, readonly) BOOL mayWriteConstants;
/* Proves the readonly interpreter cannot set an address/constant fault for
 * this access policy, regardless of input bits. Tracks initial registers,
 * moves/selections and bounded exact integer arithmetic before ARL. Unknown
 * or out-of-proof-range values remain unproven. Applies only with actual
 * context writes disabled. */
- (BOOL)hasFaultFreeReadOnlyAccess:(unsigned)access;
/* Refine the same proof with this immutable execution's 192x4 constant floats.
 * Only exact bounded integers are admitted; no host float interpreter is
 * used. The result must not be reused with other constants or context writes.
 */
- (BOOL)hasFaultFreeReadOnlyAccess:(unsigned)access
                         constants:(const float *_Nullable)constants;
- (nullable instancetype)initWithTokens:(const uint32_t *_Nullable)tokens
                                 length:(NSUInteger)length
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
BOOL nv2a_metal_writable_validate_uniforms(
    const NV2AMetalProgramUniforms *_Nullable uniforms,
    NSError *_Nullable *_Nullable error);

BOOL nv2a_metal_writable_validate(
    const uint32_t *_Nullable tokens, NSUInteger length,
    const NV2AMetalProgramUniforms *_Nullable uniforms,
    NSError *_Nullable *_Nullable error);

BOOL nv2a_metal_writable_validate_context(const uint32_t *_Nullable tokens,
                                          NSUInteger length,
                                          NSError *_Nullable *_Nullable error);

API_AVAILABLE(macos(26.0))
@interface NV2AMetalWritableResult : NSObject
@property(nonatomic, readonly) NSData *constants, *written;
@property(nonatomic, readonly, nullable) id<MTLBuffer> registers;
/* Compact raw XF retains only count/context; no raster buffer is bound. */
@property(nonatomic, readonly, nullable) id<MTLBuffer> vertices;
@property(nonatomic, readonly) NSUInteger vertexCount;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
/* The caller completes the supplied command recording before resolving
 * feedback. Resolution validates every GPU fault/context flag before returning
 * results; no GPU submission, CPU wait or PGRAPH mutation occurs while
 * encoding. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalWritableEncoding : NSObject
- (nullable NV2AMetalWritableResult *)resolveWithError:
    (NSError *_Nullable *_Nullable)error;
/* Compact output with proven absent readonly faults and known host
 * context. Raw XF has nil vertices. Borrow only in its original live recording, for GPU consumers on
 * that queue. This does not make vertex bytes CPU-readable. */
- (nullable NV2AMetalWritableResult *)
    pendingReadOnlyResultForCommands:(NV2AMetalCommands *)commands
                               error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
/* Owns its queue; caller orders previous XF work before this synchronous call.
 * XFCTX writes execute serially and feed the next vertex. With writes disabled,
 * vertices execute independently; all faults are checked before return. Output
 * buffers remain on GPU for geometry. PGRAPH is not mutated.
 * access0 means documented USER aperture, access1 FULL. Invalid accesses
 * cause backend validation errors; no hardware fault behavior is invented. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalWritableProgram : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
/* Serial writable ranges in one recording can consume the previous GPU
 * context without CPU feedback. Only constants flow between ranges; dirty
 * flags reset per range and the first fault stops all later ranges. Resolve
 * in order after completion. A previous encoding from another recording or
 * queue is rejected, including command-slot reuse after cancellation. */
- (nullable NV2AMetalWritableEncoding *)
    encodeSerialProgram:(NV2AMetalValidatedProgram *_Nullable)program
               uniforms:(const NV2AMetalProgramUniforms *)uniforms
        attributeBuffer:(id<MTLBuffer>)attributes
                  first:(NSUInteger)first
                  count:(NSUInteger)count
                 access:(unsigned)access
              rasterize:(BOOL)rasterize
               previous:(NV2AMetalWritableEncoding *_Nullable)previous
               commands:(NV2AMetalCommands *)commands
                  error:(NSError *_Nullable *_Nullable)error;
/* Captures supply already validated immutable instructions. Live uniforms,
 * input ranges, access policy and GPU faults retain the raw-token checks. */
- (nullable NV2AMetalWritableEncoding *)
       encodeProgram:(NV2AMetalValidatedProgram *_Nullable)program
            uniforms:(const NV2AMetalProgramUniforms *)uniforms
     attributeBuffer:(id<MTLBuffer>)attributes
               first:(NSUInteger)first
               count:(NSUInteger)count
              access:(unsigned)access
         writeEnable:(BOOL)writeEnable
           rasterize:(BOOL)rasterize
    compactRegisters:(BOOL)compact
            commands:(NV2AMetalCommands *)commands
               error:(NSError *_Nullable *_Nullable)error;
- (nullable NV2AMetalWritableResult *)
     executeProgram:(NV2AMetalValidatedProgram *_Nullable)program
           uniforms:(const NV2AMetalProgramUniforms *)uniforms
    attributeBuffer:(id<MTLBuffer>)attributes
              first:(NSUInteger)first
              count:(NSUInteger)count
             access:(unsigned)access
        writeEnable:(BOOL)writeEnable
          rasterize:(BOOL)rasterize
              error:(NSError *_Nullable *_Nullable)error;
- (nullable NV2AMetalWritableResult *)
      executeProgram:(NV2AMetalValidatedProgram *_Nullable)program
            uniforms:(const NV2AMetalProgramUniforms *)uniforms
     attributeBuffer:(id<MTLBuffer>)attributes
               first:(NSUInteger)first
               count:(NSUInteger)count
              access:(unsigned)access
         writeEnable:(BOOL)writeEnable
           rasterize:(BOOL)rasterize
    compactRegisters:(BOOL)compact
               error:(NSError *_Nullable *_Nullable)error;
- (nullable NV2AMetalWritableEncoding *)
       encodeTokens:(const uint32_t *)tokens
             length:(NSUInteger)length
           uniforms:(const NV2AMetalProgramUniforms *)uniforms
    attributeBuffer:(id<MTLBuffer>)attributes
              first:(NSUInteger)first
              count:(NSUInteger)count
             access:(unsigned)access
        writeEnable:(BOOL)writeEnable
          rasterize:(BOOL)rasterize
           commands:(NV2AMetalCommands *)commands
              error:(NSError *_Nullable *_Nullable)error;
/* Compact output returns nil registers. Readonly retains one GPU OR fault mask;
 * serial Writable retains its complete context/first-fault feedback without a
 * raw output buffer. Full diagnostic and context layouts remain unchanged. */
- (nullable NV2AMetalWritableEncoding *)
        encodeTokens:(const uint32_t *)tokens
              length:(NSUInteger)length
            uniforms:(const NV2AMetalProgramUniforms *)uniforms
     attributeBuffer:(id<MTLBuffer>)attributes
               first:(NSUInteger)first
               count:(NSUInteger)count
              access:(unsigned)access
         writeEnable:(BOOL)writeEnable
           rasterize:(BOOL)rasterize
    compactRegisters:(BOOL)compact
            commands:(NV2AMetalCommands *)commands
               error:(NSError *_Nullable *_Nullable)error;
- (nullable NV2AMetalWritableResult *)
    executeTokens:(const uint32_t *)tokens
           length:(NSUInteger)length
         uniforms:(const NV2AMetalProgramUniforms *)uniforms
       attributes:(NSData *)attributes
            count:(NSUInteger)count
           access:(unsigned)access
      writeEnable:(BOOL)writeEnable
            error:(NSError *_Nullable *_Nullable)error;
/* Consumes immutable GPU-decoded Float4 inputs directly. Caller completes the
 * producer queue first. first/count select a suffix without CPU readback. */
- (nullable NV2AMetalWritableResult *)
      executeTokens:(const uint32_t *)tokens
             length:(NSUInteger)length
           uniforms:(const NV2AMetalProgramUniforms *)uniforms
    attributeBuffer:(id<MTLBuffer>)attributes
              first:(NSUInteger)first
              count:(NSUInteger)count
             access:(unsigned)access
        writeEnable:(BOOL)writeEnable
              error:(NSError *_Nullable *_Nullable)error;
- (nullable NV2AMetalWritableResult *)
      executeTokens:(const uint32_t *)tokens
             length:(NSUInteger)length
           uniforms:(const NV2AMetalProgramUniforms *)uniforms
    attributeBuffer:(id<MTLBuffer>)attributes
              first:(NSUInteger)first
              count:(NSUInteger)count
             access:(unsigned)access
        writeEnable:(BOOL)writeEnable
          rasterize:(BOOL)rasterize
              error:(NSError *_Nullable *_Nullable)error;
@end
NS_ASSUME_NONNULL_END

#endif
