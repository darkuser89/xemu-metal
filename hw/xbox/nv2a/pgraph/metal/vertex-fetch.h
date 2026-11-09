/* SPDX-License-Identifier: LGPL-2.0-or-later */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_FETCH_H
#define HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_FETCH_H

#import "command.h"
#include "vertex-fetch-types.h"

NS_ASSUME_NONNULL_BEGIN

/* Host-only, capture-bound Float32 evidence; never a GPU uniform or snapshot
 * record. min/max use raw Float total order, distinguishing -0 and +0.
 * minExponent includes EVERY selected word, so zero/subnormal contributes 0.
 * Without Finite the lane remains unknown; equal min/max proves identical bits.
 */
typedef struct NV2AMetalFloatLaneSummary {
    uint32_t minBits, maxBits, minExponent, flags;
} NV2AMetalFloatLaneSummary;
enum {
    NV2AMetalFloatLaneSummaryFinite = 1u,
    NV2AMetalFloatProofMaximumWords = 4096u,
};

typedef struct NV2AMetalAttributeSource {
    __unsafe_unretained id<MTLBuffer> _Nullable buffer;
    NSUInteger offset;
    /* Zero selects the remaining buffer; a nonzero span also bounds DMA
     * sources independently of a larger shared VRAM allocation. */
    NSUInteger byteLength;
    unsigned int format;
    unsigned int count;
    unsigned int stride;
    float inline_value[4];
} NV2AMetalAttributeSource;

unsigned int nv2a_metal_attribute_size(unsigned int format, unsigned int count);

API_AVAILABLE(macos(26.0))
__attribute__((objc_subclassing_restricted))
@interface NV2AMetalFetchResult : NSObject
@property(nonatomic, readonly, nullable) id<MTLBuffer> attributes;
/* Bit i means attribute i was out of bounds. UINT32_MAX also denotes index +
 * firstVertex overflow. In summary-only mode this contains one uint32. */
@property(nonatomic, readonly, nullable) id<MTLBuffer> faults;
/* Byte offset of the bitwise OR of all faults, including Current. Read only
 * after successful GPU completion. Optional individual words precede it. */
@property(nonatomic, readonly) NSUInteger faultSummaryOffset;
@property(nonatomic, readonly) NSUInteger vertexCount;
/* When present, attributes[vertexCount] holds Current (stride-zero rules).
 * Its individual fault word exists only when requested by the fetch owner. */
@property(nonatomic, readonly) BOOL hasCurrent;
/* Copy the exact immutable shader parameters for this untouched fetch output.
 * A range proof may use them only for this buffer/range in the original live
 * recording. This does not prove absence of fetch/index faults or make GPU
 * output CPU-readable. No portable snapshot contains this metadata. */
- (BOOL)getSourceUniforms:(NV2AMetalFetchUniforms *_Nullable)uniforms
          attributeBuffer:(id<MTLBuffer>)attributes
                    first:(NSUInteger)first
                    count:(NSUInteger)count
                 commands:(NV2AMetalCommands *)commands;
/* Same binding checks, with constant decoded Float4 domains when PGRAPH owns
 * a guarded host Current capture of the corresponding stride-zero source.
 * These are proof inputs only; the recorded shader parameters stay intact. */
- (BOOL)getReadonlyProofUniforms:(NV2AMetalFetchUniforms *_Nullable)uniforms
                attributeBuffer:(id<MTLBuffer>)attributes
                          first:(NSUInteger)first
                          count:(NSUInteger)count
                       commands:(NV2AMetalCommands *)commands;
/* Optional immutable 64-lane summary array, captured only by PGRAPH after
 * source read guards. The range must be contained in the captured suffix;
 * appended Current is not covered. Every call rechecks live output ownership.
 * Raw/generic fetches and restored snapshots carry no such evidence. */
- (BOOL)getFloatProofSummaries:(NSData *_Nullable *_Nullable)summaries
                      laneMask:(uint64_t *_Nullable)laneMask
               attributeBuffer:(id<MTLBuffer>)attributes
                         first:(NSUInteger)first
                         count:(NSUInteger)count
                      commands:(NV2AMetalCommands *)commands;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/* The six formats in GL vertex.c / glsl/vsh.c, materialized as 16 Float4s for
 * either native vertex stage. count == 0 uses inline_value without a buffer.
 * stride == 0 converts the first element using pgraph_update_inline_value's
 * rules (unswizzled UB_D3D, clamped CMP); arrays use BGRA and unclamped CMP.
 * This preserves the reference paths, not a claim of Xbox hardware parity.
 * Inputs must remain unchanged until submission completes. Index bytes are
 * unsigned little-endian 16/32-bit; firstVertex is added after lookup. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalVertexFetch : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  error:(NSError *_Nullable *_Nullable)error;
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                        faultSummaryOnly:(BOOL)faultSummaryOnly
                                   error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (nullable NV2AMetalFetchResult *)
    encodeSources:(const NV2AMetalAttributeSource *)sources
            count:(NSUInteger)count
      firstVertex:(unsigned int)firstVertex
          indices:(nullable id<MTLBuffer>)indices
      indexOffset:(NSUInteger)indexOffset
        indexSize:(unsigned int)indexSize
         commands:(NV2AMetalCommands *)commands
            error:(NSError *_Nullable *_Nullable)error;
/* currentVertex is a full-input ordinal, or NSNotFound to omit Current. */
- (nullable NV2AMetalFetchResult *)
    encodeSources:(const NV2AMetalAttributeSource *)sources
            count:(NSUInteger)count
      firstVertex:(unsigned int)firstVertex
          indices:(nullable id<MTLBuffer>)indices
      indexOffset:(NSUInteger)indexOffset
        indexSize:(unsigned int)indexSize
    currentVertex:(NSUInteger)currentVertex
         commands:(NV2AMetalCommands *)commands
            error:(NSError *_Nullable *_Nullable)error;
/* The caller has already accepted the skipped prefix. Validate full input
 * spans as usual, but emit count-prefix compact records. Current selects an
 * ordinal in the full input and is appended at attributes[result.vertexCount],
 * including when it lies inside the skipped prefix. Skipped indexed values
 * must have been validated by the caller; this kernel does not read them. */
- (nullable NV2AMetalFetchResult *)
    encodeSources:(const NV2AMetalAttributeSource *)sources
            count:(NSUInteger)count
      firstVertex:(unsigned int)firstVertex
          indices:(nullable id<MTLBuffer>)indices
      indexOffset:(NSUInteger)indexOffset
        indexSize:(unsigned int)indexSize
    currentVertex:(NSUInteger)currentVertex
   skippingPrefix:(NSUInteger)prefix
         commands:(NV2AMetalCommands *)commands
            error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
#endif
