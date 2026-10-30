/* SPDX-License-Identifier: LGPL-2.0-or-later */

#ifndef HW_XBOX_NV2A_PGRAPH_METAL_SURFACE_PGRAPH_H
#define HW_XBOX_NV2A_PGRAPH_METAL_SURFACE_PGRAPH_H

#import "surface-cache.h"
typedef struct NV2AState NV2AState;

NS_ASSUME_NONNULL_BEGIN

typedef struct NV2AMetalSurfaceBinding {
    NV2AMetalSurfaceConfig config;
    NSUInteger address;
} NV2AMetalSurfaceBinding;
typedef struct NV2AMetalSurfaceBindings {
    NV2AMetalSurfaceBinding color, zeta;
} NV2AMetalSurfaceBindings;
enum { NV2AMetalSurfaceBindingsBytes = 68 };
/* Direct validation for typed internal bindings. width==0 means absent;
 * portable packets additionally require absent records to contain only zeros. */
BOOL nv2a_metal_surface_bindings_validate(
    NV2AMetalSurfaceBindings bindings, NSError *_Nullable *_Nullable error);
/* Portable bound attachment layouts. Empty records are all zero. */
NSData *nv2a_metal_surface_bindings_encode(NV2AMetalSurfaceBindings bindings);
BOOL nv2a_metal_surface_bindings_decode(
    NSData *data, NV2AMetalSurfaceBindings *_Nullable bindings,
    NSError *_Nullable *_Nullable error);

/* Native QEMU adapter. NV2AState/VRAM outlive this object; close it on the
 * PGRAPH thread after stopping vCPU access. The RAM is wrapped without copying.
 * prepare/mark/flush/close require pg.lock; processPending requires pfifo.lock
 * and drops it while servicing the vCPU requests under pg.lock. */
API_AVAILABLE(macos(26.0))
@interface NV2AMetalPGRAPHSurfaces : NSObject
@property(nonatomic, readonly) NV2AMetalSurfaceCache *cache;
@property(nonatomic, readonly, nullable) NV2AMetalCachedSurface *color, *zeta;
- (nullable instancetype)initWithState:(NV2AState *)state
                                 error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (BOOL)prepareColor:(BOOL)color
                zeta:(BOOL)zeta
               error:(NSError *_Nullable *_Nullable)error;
- (NV2AMetalSurfaceBindings)captureBindings;
- (BOOL)prepareBindings:(NV2AMetalSurfaceBindings)bindings
                  error:(NSError *_Nullable *_Nullable)error;
/* Begin captures immutable layouts without creating an empty GPU section.
 * NO still performs required uploads. The regular preparation methods above
 * acquire recording ownership before a later draw/clear writes attachments. */
- (BOOL)prepareColor:(BOOL)color
                zeta:(BOOL)zeta
        forRendering:(BOOL)forRendering
               error:(NSError *_Nullable *_Nullable)error;
- (BOOL)prepareBindings:(NV2AMetalSurfaceBindings)bindings
           forRendering:(BOOL)forRendering
                  error:(NSError *_Nullable *_Nullable)error;
/* Release guest ownership as GL/VK do. TCG access hooks preserve dirty GPU
 * attachments until an actual RAM consumer needs them; unmonitored CPUs use
 * the synchronous download path. */
- (BOOL)releaseColor:(BOOL)color
                zeta:(BOOL)zeta
               error:(NSError *_Nullable *_Nullable)error;
- (BOOL)downloadColor:(BOOL)color
                 zeta:(BOOL)zeta
                error:(NSError *_Nullable *_Nullable)error;
/* Captured NV097_CLEAR_SURFACE state with native masked/dithered rendering.
 * Unsupported attachment formats and inverted rectangles are rejected. */
- (BOOL)clearSurface:(uint32_t)parameter
               error:(NSError *_Nullable *_Nullable)error;
- (BOOL)markColorWritten:(BOOL)color
             zetaWritten:(BOOL)zeta
                   error:(NSError *_Nullable *_Nullable)error;
- (BOOL)flushWithError:(NSError *_Nullable *_Nullable)error;
- (BOOL)discardForRestoreWithError:(NSError *_Nullable *_Nullable)error;
- (BOOL)closeWithError:(NSError *_Nullable *_Nullable)error;

/* CPU callers post to PFIFO and wait; they do not encode GPU work themselves.
 * The request must finish before the actual read/write. Do not call from the
 * PGRAPH worker or while holding pg/pfifo locks. QEMU's callbacks are before
 * access; unfenced concurrent guest CPU/GPU writes are not made atomic. */
- (BOOL)requestCPUAccessAtAddress:(NSUInteger)address
                           length:(NSUInteger)length
                            write:(BOOL)write
                            error:(NSError *_Nullable *_Nullable)error;
- (BOOL)processPendingWithError:(NSError *_Nullable *_Nullable)error;
/* PFIFO worker, with pfifo.lock held. Binding references/exported flags are
 * worker-owned; register writes and VMState loading also acquire PFIFO.
 * Checks only an atomic request bit and dirty stamps, without taking PGRAPH
 * or cache metadata locks. The last two published entries are retained until
 * the next service or an explicit flush/restore. */
- (BOOL)needsCPUService;
/* PGRAPH worker variant with pg.lock already held and pfifo.lock released. */
- (BOOL)processCPURequestsWithError:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
#endif
