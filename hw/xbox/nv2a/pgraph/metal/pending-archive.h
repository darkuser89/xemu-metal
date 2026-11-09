#ifndef HW_XBOX_NV2A_PGRAPH_METAL_PENDING_ARCHIVE_H
#define HW_XBOX_NV2A_PGRAPH_METAL_PENDING_ARCHIVE_H
/* Canonical pending-vertex transport. SPDX-License-Identifier:
 * GPL-2.0-only OR GPL-3.0-only */
#import "pending-journal.h"
#include "geometry-types.h"
NS_ASSUME_NONNULL_BEGIN
@interface NV2AMetalPendingArchive : NSObject
@property(nonatomic, readonly) NSArray<NV2AMetalPendingInput *> *inputs;
/* Physical transformed records and host-order uint32 logical ordinals. Empty
 * remap data denotes a linear stream with physicalCount == input.count. */
@property(nonatomic, readonly) NSArray<NSData *> *physicalVertices, *remaps;
/* Compatibility view in logical order. Native capture/restore should use the
 * physical representation to avoid expanding repeated vertices. */
@property(nonatomic, readonly) NSArray<NSData *> *vertices;
/* Caller has completed GPU copies and gathered each independent stream's raw
 * transformed bytes, including any cached hidden last range. No float math.
 * The bounded transport is separate from existing small vertex captures. */
- (nullable instancetype)initWithInputs:
                             (NSArray<NV2AMetalPendingInput *> *)inputs
                               vertices:(NSArray<NSData *> *)vertices
                                  limit:(NSUInteger)limit
                                  error:(NSError *_Nullable *_Nullable)error;
/* Indexed streams have 1..input.count physical records and exactly input.count
 * remap entries, each below the physical count. Both payload arrays are copied.
 * All-linear archives retain the byte-identical version 1 wire format; indexed
 * archives use version 2, preserving physical records and logical remaps. */
- (nullable instancetype)initWithInputs:
                             (NSArray<NV2AMetalPendingInput *> *)inputs
                       physicalVertices:(NSArray<NSData *> *)physicalVertices
                                 remaps:(NSArray<NSData *> *)remaps
                                  limit:(NSUInteger)limit
                                  error:(NSError *_Nullable *_Nullable)error;
- (nullable instancetype)initWithData:(NSData *)data
                                limit:(NSUInteger)limit
                                error:(NSError *_Nullable *_Nullable)error;
- (NSData *)data;
/* CPU transport test helper. Native restore must upload the already transformed
 * bytes to MTLBuffers before publishing a journal; it must not rerun vertices.
 */
- (nullable NV2AMetalPendingJournal *)CPUJournal;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
NS_ASSUME_NONNULL_END
#endif
