/* Indexed source permutation for the existing compute/raster comparisons.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#import "hw/xbox/nv2a/pgraph/metal/vertex-stream.h"

static NV2AMetalIndexedVertices *
indexed_raster_source(id<MTLDevice> device, const NV2AMetalVertex *vertices,
                      NSUInteger count, NSError **error)
{
    NSMutableData *remap =
        [NSMutableData dataWithLength:(count + 5) * sizeof(uint32_t)];
    uint32_t *indices = remap.mutableBytes;
    NSMutableData *unique =
        [NSMutableData dataWithLength:count * sizeof(*vertices)];
    NV2AMetalVertex *records = unique.mutableBytes;
    NSUInteger uniqueCount = 0;
    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger record = 0;
        while (record < uniqueCount &&
               memcmp(&records[record], &vertices[i], sizeof(*vertices)))
            record++;
        if (record == uniqueCount)
            records[uniqueCount++] = vertices[i];
        indices[i + 5] = (uint32_t)record;
    }
    id<MTLBuffer> physical =
        [device newBufferWithLength:(uniqueCount + 1) * sizeof(*vertices)
                            options:MTLResourceStorageModeShared];
    assert(physical);
    /* Poison record zero and reverse physical order. The exact physical
     * allocation is smaller than the logical source for duplicate inputs. */
    memset(physical.contents, 0x5a, physical.length);
    for (NSUInteger i = 0; i < uniqueCount; i++)
        ((NV2AMetalVertex *)physical.contents)[uniqueCount - i] = records[i];
    for (NSUInteger i = 0; i < count; i++)
        indices[i + 5] = (uint32_t)uniqueCount - indices[i + 5];
    NV2AMetalIndexedVertices *owner =
        [[NV2AMetalIndexedVertices alloc] initWithVertices:physical
                                             physicalCount:uniqueCount + 1
                                                     remap:remap
                                                     error:error];
    assert(owner && owner.vertexCount == count + 5);
    return owner;
}

static NV2AMetalVertexSlice *
indexed_raster_slice(NV2AMetalIndexedVertices *owner, NSUInteger count,
                     NV2AMetalCommands *commands, NSError **error)
{
    NV2AMetalVertexStream *stream =
        [[NV2AMetalVertexStream alloc] initWithDevice:commands.device
                                                limit:count
                                                error:error];
    assert(stream);
    BOOL appended = [stream appendIndexedVertices:owner
                                            first:5
                                            count:count
                                            error:error];
    assert(appended);
    NV2AMetalVertexSlice *slice =
        [stream encodeSliceForDrawingWithCommands:commands error:error];
    assert(slice && slice.indexedVertices == owner && slice.firstVertex == 5);
    return slice;
}
