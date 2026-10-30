/* SPDX-License-Identifier: LGPL-2.0-or-later */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_FETCH_H
#define HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_FETCH_H

#import "command.h"
#include "vertex-fetch-types.h"

NS_ASSUME_NONNULL_BEGIN

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
@interface NV2AMetalFetchResult : NSObject
@property(nonatomic, readonly, nullable) id<MTLBuffer> attributes;
/* One uint32 per output vertex: bit i means attribute i was out of bounds;
 * UINT32_MAX also denotes index + firstVertex overflow. These are validation
 * faults, not hardware results. The draw frontend must reject faulted draws. */
@property(nonatomic, readonly, nullable) id<MTLBuffer> faults;
/* Byte offset of an extra uint32 containing the bitwise OR of all vertex
 * faults. Read only after successful GPU completion; individual fault words
 * and the optional Current word retain their original layout. */
@property(nonatomic, readonly) NSUInteger faultSummaryOffset;
@property(nonatomic, readonly) NSUInteger vertexCount;
/* When present, attributes[vertexCount] and faults[vertexCount] hold the
 * selected vertex converted with Current (stride-zero) rules. */
@property(nonatomic, readonly) BOOL hasCurrent;
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
