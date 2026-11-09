#ifndef HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_STREAM_H
#define HW_XBOX_NV2A_PGRAPH_METAL_VERTEX_STREAM_H
/* Native Metal4 vertex-stream assembly.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "command.h"
#include "geometry-types.h"

NS_ASSUME_NONNULL_BEGIN
/* Immutable logical topology over an immutable physical vertex buffer. The
 * physical records start at zero; remap is copied and every uint32 index is
 * validated before publication. Producers must finish before host inspection.
 */
__attribute__((objc_subclassing_restricted))
API_AVAILABLE(macos(26.0))
@interface NV2AMetalIndexedVertices : NSObject
@property(nonatomic, readonly) id<MTLBuffer> vertices, indices;
@property(nonatomic, readonly) NSData *remap;
@property(nonatomic, readonly) NSUInteger physicalVertexCount, vertexCount;
- (nullable instancetype)initWithVertices:(id<MTLBuffer>)vertices
                            physicalCount:(NSUInteger)physicalCount
                                    remap:(NSData *)remap
                                    error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
/* Immutable drawing view. The valid range is measured in vertices; buffer
 * length may include unrelated prefix/suffix records. No bytes are copied. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalVertexSlice : NSObject
@property(nonatomic, readonly) id<MTLBuffer> buffer;
/* When present, buffer is physical and firstVertex indexes the logical remap. */
@property(nonatomic, readonly, nullable)
    NV2AMetalIndexedVertices *indexedVertices;
@property(nonatomic, readonly) NSUInteger firstVertex, vertexCount;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

API_AVAILABLE(macos(26.0))
@interface NV2AMetalVertexStream : NSObject
@property(nonatomic, readonly) NSUInteger vertexCount;
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  limit:(NSUInteger)limit
                                  error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
/* Appending does not transform or draw. Inputs must remain immutable until
 * commands using them finish. Independent primitive streams use separate
 * instances; a state-program boundary does not end a strip, fan or polygon. */
- (BOOL)appendVertices:(nullable id<MTLBuffer>)vertices
                 first:(NSUInteger)first
                 count:(NSUInteger)count
                 error:(NSError *_Nullable *_Nullable)error;
/* first/count select logical remap entries; the owner retains both resources. */
- (BOOL)appendIndexedVertices:(NV2AMetalIndexedVertices *)vertices
                        first:(NSUInteger)first
                        count:(NSUInteger)count
                        error:(NSError *_Nullable *_Nullable)error;
/* Snapshot-only zero transport. No allocation or GPU encoding while appending;
 * drawing variants reject streams containing these discarded segments. */
- (BOOL)appendDiscardedVertices:(NSUInteger)count
                          error:(NSError *_Nullable *_Nullable)error;
/* Caller has completed the producers. Return a host copy when every source
 * is shared or discarded, or nil when GPU readback is required. */
- (nullable NSData *)completedHostVertexData;
/* Snapshot variants retain only referenced physical records and return a
 * logical remap. Discarded spans use one zero record. The host variant returns
 * nil for private sources; neither variant replays vertex programs. */
- (nullable NSData *)completedHostCompactVertexDataWithRemap:
    (NSData *_Nullable *_Nullable)remap;
- (nullable NV2AMetalVertexSlice *)
    encodeCompactSliceForCaptureWithCommands:(NV2AMetalCommands *)commands
                                       error:(NSError *_Nullable *_Nullable)error;
/* Requires a live recording. Copies all segments into a new shared buffer
 * with exactly vertexCount vertices, suitable for snapshot readback after
 * GPU completion. Empty streams return nil without an error. */
- (nullable id<MTLBuffer>)encodeWithCommands:(NV2AMetalCommands *)commands
                                       error:
                                           (NSError *_Nullable *_Nullable)error;
/* Requires a live recording. A contiguous linear stream starting at buffer
 * offset zero reuses its immutable source; other streams are joined on the
 * MTL4 encoder. Indexed streams are gathered into logical vertex order. Only vertexCount vertices are valid, regardless of buffer length.
 * Consumers must not mutate the result and must synchronize with its GPU
 * producer. The recording retains the resident result until completion.
 * Empty streams return nil without an error. No CPU vertex readback occurs. */
- (nullable id<MTLBuffer>)
    encodeForDrawingWithCommands:(NV2AMetalCommands *)commands
                           error:(NSError *_Nullable *_Nullable)error;
/* Reuse any one contiguous linear or indexed source range. Multiple ranges
 * join on GPU at zero; indexed joins retain a compact physical buffer and
 * logical remap. The same immutability and recording ownership rules apply. */
- (nullable NV2AMetalVertexSlice *)
    encodeSliceForDrawingWithCommands:(NV2AMetalCommands *)commands
                                error:(NSError *_Nullable *_Nullable)error;
@end
NS_ASSUME_NONNULL_END
#endif
