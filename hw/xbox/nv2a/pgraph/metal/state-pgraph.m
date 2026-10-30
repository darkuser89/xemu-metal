/* Two-phase native State/PGRAPH transaction.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#import "state-pgraph.h"

_Static_assert(sizeof(((PGRAPHState *)0)->vsh_constants) == 192 * 16,
               "Native XFCTX layout matches PGRAPH");
_Static_assert(sizeof(((PGRAPHState *)0)->vertex_state_shader_v0) == 16,
               "State launch vector layout");

static BOOL state_error(NSError **error, NSString *message)
{
    if (error)
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.state-pgraph"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    return NO;
}
@interface NV2AMetalStateTransaction ()
- (instancetype)initWithResult:(NV2AMetalStateResult *)result
                      original:(NSData *)original
                         state:(PGRAPHState *)state;
@end
@implementation NV2AMetalStateTransaction {
    NSData *_original;
    PGRAPHState *_origin;
    BOOL _committed;
}
- (instancetype)initWithResult:(NV2AMetalStateResult *)result
                      original:(NSData *)original
                         state:(PGRAPHState *)state
{
    self = [super init];
    if (self) {
        _result = result;
        _original = [original copy];
        _origin = state;
    }
    return self;
}
- (BOOL)commitWithState:(PGRAPHState *)state error:(NSError **)error
{
    if (_committed || !state || state != _origin ||
        _original.length != sizeof(state->vsh_constants) ||
        _result.constants.length != sizeof(state->vsh_constants) ||
        _result.written.length != 192 * 4 ||
        memcmp(state->vsh_constants, _original.bytes, _original.length))
        return state_error(error, @"Stale or invalid native State transaction");
    const uint8_t *flags = _result.written.bytes;
    for (unsigned row = 0; row < 192; row++) {
        uint32_t flag;
        memcpy(&flag, flags + row * 4, 4);
        if (flag > 1)
            return state_error(error, @"Invalid native State write flag");
    }
    const uint8_t *constants = _result.constants.bytes;
    for (unsigned row = 0; row < 192; row++) {
        uint32_t flag;
        memcpy(&flag, flags + row * 4, 4);
        if (flag) {
            memcpy(state->vsh_constants[row], constants + row * 16, 16);
            state->vsh_constants_dirty[row] = true;
        }
    }
    _committed = YES;
    return YES;
}
@end
@implementation NV2AMetalPGRAPHStateProgram {
    NV2AMetalStateProgram *_program;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    _program = [[NV2AMetalStateProgram alloc] initWithDevice:device
                                                       error:error];
    return _program ? self : nil;
}
- (NV2AMetalStateTransaction *)executeWithState:(PGRAPHState *)state
                                   programStart:(NSUInteger)start
                                          error:(NSError **)error
{
    if (!state || start >= NV2A_MAX_TRANSFORM_PROGRAM_LENGTH) {
        state_error(error, @"Invalid native State program start");
        return nil;
    }
    NSUInteger length = 0;
    for (NSUInteger slot = start; slot < NV2A_MAX_TRANSFORM_PROGRAM_LENGTH;
         slot++) {
        length++;
        if (state->program_data[slot][3] & 1)
            break;
    }
    NSData *original = [NSData dataWithBytes:state->vsh_constants
                                      length:sizeof(state->vsh_constants)];
    NSData *launch =
        [NSData dataWithBytes:state->vertex_state_shader_v0
                       length:sizeof(state->vertex_state_shader_v0)];
    unsigned full =
        !!(pgraph_reg_r(state, NV_PGRAPH_CSV0_D) & NV_PGRAPH_CSV0_D_RANGE_MODE);
    NV2AMetalStateResult *result =
        [_program executeTokens:state->program_data[start]
                         length:length
                      constants:original
                         launch:launch
                         access:full
                          error:error];
    if (!result)
        return nil;
    return [[NV2AMetalStateTransaction alloc] initWithResult:result
                                                    original:original
                                                       state:state];
}
@end
