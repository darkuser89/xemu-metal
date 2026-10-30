#import "vertex-writable.h"
#import "lru-cache.h"
#include <limits.h>
#include <math.h>
#include <string.h>
#include "vertex-context-types.h"
#include "vertex-context-source.h"
_Static_assert(sizeof(NV2AMetalWritableContext) == 3856,
               "Writable context layout");
_Static_assert(sizeof(NV2AMetalWritableParameters) ==
                   sizeof(NV2AMetalProgramUniforms) + 16,
               "Writable parameters layout");
static BOOL program_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.nv2a.metal4.vertex-program"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

/* Translate the verified NV2A fields once on the CPU. The packed source below
 * is internal to this backend and never used as a hardware definition. */
static NV2AMetalProgramInstruction decode_token(const uint32_t *token)
{
    NV2AMetalProgramInstruction op = {
        .mac = (token[1] >> 21) & 15,
        .ilu = (token[1] >> 25) & 7,
        .constant_index = (token[1] >> 13) & 255,
        .attribute_index = (token[1] >> 9) & 15,
        .mac_mask = (token[3] >> 24) & 15,
        .ilu_mask = (token[3] >> 16) & 15,
        .output_mask = (token[3] >> 12) & 15,
        .output_register = (token[3] >> 3) & 255,
        .output_mux = (token[3] >> 2) & 1,
        .temp_register = (token[3] >> 20) & 15,
        .relative = (token[3] >> 1) & 1,
    };
    /* Keep OGL/legacy vertex-output addressing; constants use all eight bits.
     * This compatibility rule is not a new Xbox hardware measurement. */
    if (token[3] & (1u << 11))
        op.output_register &= 15u;
    unsigned mux[] = { (token[2] >> 26) & 3, (token[2] >> 11) & 3,
                       (token[3] >> 28) & 3 };
    unsigned reg[] = { token[2] >> 28, (token[2] >> 13) & 15,
                       ((token[2] & 3) << 2) | (token[3] >> 30) };
    unsigned neg[] = { (token[1] >> 8) & 1, (token[2] >> 25) & 1,
                       (token[2] >> 10) & 1 };
    for (unsigned s = 0; s < 3; s++) {
        op.source[s] = mux[s] | (reg[s] << 2) | (neg[s] << 14);
        unsigned word = s == 0 ? token[1] : token[2];
        unsigned start = s == 0 ? 6 : s == 1 ? 23 : 8;
        for (unsigned component = 0; component < 4; component++) {
            op.source[s] |= ((word >> (start - 2 * component)) & 3)
                            << (6 + 2 * component);
        }
    }
    return op;
}

static BOOL valid_instruction(const NV2AMetalProgramInstruction *op,
                              const uint32_t *token, NSError **error)
{
    if (op->mac > NV2AMetalMACArl || op->ilu > NV2AMetalILULit) {
        return program_error(error, @"Invalid NV2A vertex-program opcode");
    }
    BOOL needed[] = {
        op->mac != NV2AMetalMACNop,
        op->mac != NV2AMetalMACNop && op->mac != NV2AMetalMACMov &&
            op->mac != NV2AMetalMACAdd && op->mac != NV2AMetalMACArl,
        op->mac == NV2AMetalMACAdd || op->mac == NV2AMetalMACMad ||
            op->ilu != NV2AMetalILUNop,
    };
    for (unsigned s = 0; s < 3; s++) {
        if (!needed[s]) {
            continue;
        }
        unsigned mux = op->source[s] & 3;
        unsigned reg = (op->source[s] >> 2) & 15;
        if (mux == 0 || (mux == 1 && reg > 12) ||
            (mux == 3 && !op->relative &&
             op->constant_index >= NV2A_METAL_VP_CONSTANTS)) {
            return program_error(error, @"Invalid NV2A vertex-program operand");
        }
    }
    if (op->temp_register > 12 &&
        ((op->mac != NV2AMetalMACNop && op->mac != NV2AMetalMACArl &&
          op->mac_mask) ||
         (op->mac == NV2AMetalMACNop && op->ilu != NV2AMetalILUNop &&
          op->ilu_mask))) {
        return program_error(error, @"Invalid NV2A temporary destination");
    }
    BOOL output =
        op->output_mask && (op->output_mux == 0 ? op->mac != NV2AMetalMACNop :
                                                  op->ilu != NV2AMetalILUNop);
    BOOL vertex_output = !!(token[3] & (1u << 11));
    BOOL bad_destination = vertex_output ? op->output_register == 1 ||
                                               op->output_register == 2 ||
                                               op->output_register > 12 :
                                           op->output_register >= 192;
    if (output && (bad_destination ||
                   (op->output_mux == 0 && op->mac == NV2AMetalMACArl))) {
        return program_error(error,
                             @"Unsupported NV2A constant/address/output write");
    }
    return YES;
}

static BOOL program_uniforms_valid(const NV2AMetalProgramUniforms *u)
{
    return u && isfinite(u->surface_size[0]) && u->surface_size[0] > 0 &&
           isfinite(u->surface_size[1]) && u->surface_size[1] > 0 &&
           isfinite(u->zmax) && u->zmax > 0 && isfinite(u->point_scale) &&
           u->point_scale > 0 &&
           (!u->fog_enable ||
            (u->fog_mode <= 7 && u->fog_mode != 2 && u->fog_mode != 6));
}
static BOOL decode_program(const uint32_t *tokens, NSUInteger length,
                           NV2AMetalProgramInstruction *decoded,
                           NSUInteger *slots, NSError **error)
{
    if (!tokens || !length || length > NV2A_METAL_VP_SLOTS) {
        return program_error(error, @"Invalid NV2A vertex program span");
    }
    BOOL final = NO;
    for (*slots = 0; *slots < length; (*slots)++) {
        decoded[*slots] = decode_token(tokens + 4 * (*slots));
        if (!valid_instruction(&decoded[*slots], tokens + 4 * (*slots),
                               error)) {
            return NO;
        }
        if (tokens[4 * (*slots) + 3] & (1u << 11))
            decoded[*slots].output_register |= 256u;
        if (tokens[4 * (*slots) + 3] & 1) {
            (*slots)++;
            final = YES;
            break;
        }
    }
    if (!final) {
        program_error(error, @"NV2A vertex program has no final instruction");
        return NO;
    }
    return YES;
}
/* Internal integer proof intervals, not a host floating-point interpreter.
 * +/-256 covers every potentially valid offset of an eight-bit constant base.
 * Products and four-term sums stay within +/-2^18, so the existing Kelvin
 * RZ/FTZ arithmetic preserves these integers exactly. Its zero-wins product
 * also proves zero against unknown bits, after all operand aperture checks.
 * Other unknown values remain unproven. ARL's
 * floor(x + .001f) preserves every integer in this bounded interval. */
typedef struct NV2AMetalProofRange {
    int low, high;
} NV2AMetalProofRange;
static const NV2AMetalProofRange readonly_unknown = { 1, 0 };
static BOOL readonly_known(NV2AMetalProofRange value)
{
    return value.low <= value.high;
}
static NV2AMetalProofRange readonly_range(int low, int high)
{
    return low < -256 || high > 256 ? readonly_unknown :
                                      (NV2AMetalProofRange){ low, high };
}
static NV2AMetalProofRange readonly_constant(const float *constant)
{
    uint32_t bits;
    memcpy(&bits, constant, sizeof(bits));
    unsigned magnitude = bits & 0x7fffffffu, exponent = magnitude >> 23;
    if (!magnitude)
        return (NV2AMetalProofRange){ 0, 0 };
    if (exponent < 127 || exponent > 135)
        return readonly_unknown;
    unsigned shift = 150 - exponent,
             mantissa = (magnitude & 0x7fffff) | 0x800000;
    if (mantissa & ((1u << shift) - 1))
        return readonly_unknown;
    int value = mantissa >> shift;
    if (bits >> 31)
        value = -value;
    return readonly_range(value, value);
}
static NV2AMetalProofRange
readonly_source_domain(unsigned source, unsigned lane,
                       const NV2AMetalProofRange registers[13][4],
                       const float *constants, NV2AMetalProofRange rows)
{
    unsigned component = (source >> (6 + 2 * lane)) & 3u;
    NV2AMetalProofRange value = readonly_unknown;
    if ((source & 3u) == 1u) {
        unsigned reg = (source >> 2) & 15u;
        value = registers[reg][component];
    } else if ((source & 3u) == 3u && constants) {
        /* Operand aperture checks precede this refinement, including every
         * possible relative row. An unknown row/lane poisons the interval. */
        for (int row = rows.low; row <= rows.high; row++) {
            NV2AMetalProofRange one =
                readonly_constant(constants + 4 * row + component);
            if (!readonly_known(one))
                return readonly_unknown;
            value = row == rows.low ?
                        one :
                        (NV2AMetalProofRange){ MIN(value.low, one.low),
                                               MAX(value.high, one.high) };
        }
    } else
        return readonly_unknown;
    return source & (1u << 14) ?
               (NV2AMetalProofRange){ -value.high, -value.low } :
               value;
}
static BOOL readonly_product(NV2AMetalProofRange a, NV2AMetalProofRange b,
                             int *low, int *high)
{
    /* vp_multiply_rz returns +0 before examining NaN/Inf if either operand
     * has a zero exponent. A known integer zero is sufficient here. */
    if ((a.low == 0 && a.high == 0) || (b.low == 0 && b.high == 0)) {
        *low = *high = 0;
        return YES;
    }
    if (!readonly_known(a) || !readonly_known(b))
        return NO;
    int products[] = { a.low * b.low, a.low * b.high, a.high * b.low,
                       a.high * b.high };
    *low = *high = products[0];
    for (unsigned i = 1; i < 4; i++) {
        *low = MIN(*low, products[i]);
        *high = MAX(*high, products[i]);
    }
    return YES;
}
static NV2AMetalProofRange
readonly_arithmetic(unsigned opcode, unsigned lane,
                    const NV2AMetalProofRange inputs[3][4])
{
    NV2AMetalProofRange a = inputs[0][lane], c = inputs[2][lane];
    int low, high;
    if (opcode == NV2AMetalMACAdd) {
        if (readonly_known(a) && readonly_known(c))
            return readonly_range(a.low + c.low, a.high + c.high);
    } else if (opcode == NV2AMetalMACMul || opcode == NV2AMetalMACMad ||
               (opcode == NV2AMetalMACDst && lane == 1)) {
        if (readonly_product(a, inputs[1][lane], &low, &high)) {
            if (opcode != NV2AMetalMACMad)
                return readonly_range(low, high);
            if (readonly_known(c))
                return readonly_range(low + c.low, high + c.high);
        }
    } else if (opcode == NV2AMetalMACDp3 || opcode == NV2AMetalMACDph ||
               opcode == NV2AMetalMACDp4) {
        int sum_low = 0, sum_high = 0;
        unsigned count = opcode == NV2AMetalMACDp3 ? 3 : 4;
        for (unsigned i = 0; i < count; i++) {
            a = opcode == NV2AMetalMACDph && i == 3 ?
                    (NV2AMetalProofRange){ 1, 1 } :
                    inputs[0][i];
            if (!readonly_product(a, inputs[1][i], &low, &high))
                return readonly_unknown;
            sum_low += low;
            sum_high += high;
        }
        return readonly_range(sum_low, sum_high);
    }
    return readonly_unknown;
}
static void readonly_write_domains(NV2AMetalProofRange destination[4],
                                   const NV2AMetalProofRange value[4],
                                   unsigned mask)
{
    for (unsigned lane = 0; lane < 4; lane++)
        if (mask & (8u >> lane))
            destination[lane] = value[lane];
}
static unsigned
readonly_fault_free_access(const NV2AMetalProgramInstruction *program,
                           NSUInteger slots, const float *constants)
{
    NV2AMetalProofRange registers[13][4] = { 0 }, address = { 0, 0 };
    unsigned access = 3u;
    registers[12][3] = (NV2AMetalProofRange){ 1, 1 };
    for (NSUInteger slot = 0; slot < slots; slot++) {
        const NV2AMetalProgramInstruction *op = &program[slot];
        BOOL needed[] = {
            op->mac != NV2AMetalMACNop,
            op->mac != NV2AMetalMACNop && op->mac != NV2AMetalMACMov &&
                op->mac != NV2AMetalMACAdd && op->mac != NV2AMetalMACArl,
            op->mac == NV2AMetalMACAdd || op->mac == NV2AMetalMACMad ||
                op->ilu != NV2AMetalILUNop,
        };
        NV2AMetalProofRange inputs[3][4], mac[4], ilu[4];
        for (unsigned lane = 0; lane < 4; lane++) {
            mac[lane] = ilu[lane] = readonly_unknown;
            for (unsigned source = 0; source < 3; source++)
                inputs[source][lane] = readonly_unknown;
        }
        /* All used operands precede output, paired ILU, temp and IDX writes,
         * even for zero destination masks. Unused indices need not be valid. */
        for (unsigned source = 0; source < 3; source++) {
            if (!needed[source])
                continue;
            unsigned operand = op->source[source];
            NV2AMetalProofRange rows = { 0, 0 };
            if ((operand & 3u) == 3u) {
                NV2AMetalProofRange offsets =
                    op->relative ? address : (NV2AMetalProofRange){ 0, 0 };
                int low = (int)op->constant_index + offsets.low;
                int high = (int)op->constant_index + offsets.high;
                if (low < 0 || high >= NV2A_METAL_VP_CONSTANTS)
                    return 0;
                if (low < 96 && (op->relative || (low != 58 && low != 59)))
                    access &= ~1u;
                rows = (NV2AMetalProofRange){ low, high };
            }
            for (unsigned lane = 0; lane < 4; lane++)
                inputs[source][lane] = readonly_source_domain(
                    operand, lane, registers, constants, rows);
        }
        if (op->mac == NV2AMetalMACArl && !readonly_known(inputs[0][0]))
            return 0; /* Unknown ARL may fault even without a later read. */
        for (unsigned lane = 0; lane < 4; lane++) {
            if (op->mac == NV2AMetalMACMov)
                mac[lane] = inputs[0][lane];
            else if (op->mac == NV2AMetalMACSlt || op->mac == NV2AMetalMACSge) {
                mac[lane] = (NV2AMetalProofRange){ 0, 1 };
                NV2AMetalProofRange a = inputs[0][lane], b = inputs[1][lane];
                if (readonly_known(a) && readonly_known(b)) {
                    if (a.high < b.low) {
                        int value = op->mac == NV2AMetalMACSlt;
                        mac[lane] = (NV2AMetalProofRange){ value, value };
                    } else if (a.low >= b.high && (a.low != 0 || b.high != 0)) {
                        /* vp_less orders -0 below +0. Integer intervals do
                         * not retain that distinction, so zero ties stay
                         * unproven even when both endpoints are known. */
                        int value = op->mac == NV2AMetalMACSge;
                        mac[lane] = (NV2AMetalProofRange){ value, value };
                    }
                }
            } else if ((op->mac == NV2AMetalMACMin ||
                        op->mac == NV2AMetalMACMax) &&
                       readonly_known(inputs[0][lane]) &&
                       readonly_known(inputs[1][lane]))
                mac[lane] =
                    op->mac == NV2AMetalMACMin ?
                        (NV2AMetalProofRange){
                            MIN(inputs[0][lane].low, inputs[1][lane].low),
                            MIN(inputs[0][lane].high, inputs[1][lane].high)
                        } :
                        (NV2AMetalProofRange){
                            MAX(inputs[0][lane].low, inputs[1][lane].low),
                            MAX(inputs[0][lane].high, inputs[1][lane].high)
                        };
            else
                mac[lane] = readonly_arithmetic(op->mac, lane, inputs);
            if (op->ilu == NV2AMetalILUMov)
                ilu[lane] = inputs[2][lane];
        }
        if (op->mac == NV2AMetalMACDst) {
            mac[0] = (NV2AMetalProofRange){ 1, 1 };
            mac[2] = inputs[0][2];
            mac[3] = inputs[1][3];
        }
        if (op->ilu >= NV2AMetalILUExp)
            ilu[3] = (NV2AMetalProofRange){ 1, 1 };
        if (op->ilu == NV2AMetalILULit)
            ilu[0] = (NV2AMetalProofRange){ 1, 1 };
        if (op->output_register == 256u && op->output_mask) {
            if (op->output_mux && op->ilu != NV2AMetalILUNop)
                readonly_write_domains(registers[12], ilu, op->output_mask);
            else if (!op->output_mux && op->mac != NV2AMetalMACNop &&
                     op->mac != NV2AMetalMACArl)
                readonly_write_domains(registers[12], mac, op->output_mask);
        }
        BOOL paired = op->mac != NV2AMetalMACNop && op->ilu != NV2AMetalILUNop;
        if (op->ilu != NV2AMetalILUNop && op->ilu_mask)
            readonly_write_domains(registers[paired ? 1 : op->temp_register],
                                   ilu, op->ilu_mask);
        if (op->mac == NV2AMetalMACArl)
            address = inputs[0][0];
        else if (op->mac != NV2AMetalMACNop && op->mac_mask &&
                 !(paired && op->temp_register == 1))
            readonly_write_domains(registers[op->temp_register], mac,
                                   op->mac_mask);
    }
    return access;
}
@implementation NV2AMetalValidatedProgram {
    unsigned _faultFreeReadOnlyAccess;
}
- (BOOL)hasFaultFreeReadOnlyAccess:(unsigned)access
{
    return access <= 1 && (_faultFreeReadOnlyAccess & (1u << access));
}
- (BOOL)hasFaultFreeReadOnlyAccess:(unsigned)access
                         constants:(const float *)constants
{
    if ([self hasFaultFreeReadOnlyAccess:access])
        return YES;
    return access <= 1 && constants &&
           (readonly_fault_free_access(_instructions.bytes, _slots, constants) &
            (1u << access));
}
- (instancetype)initWithTokens:(const uint32_t *)tokens
                        length:(NSUInteger)length
                         error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    if (!tokens || !length || length > NV2A_METAL_VP_SLOTS) {
        program_error(error, @"Invalid NV2A vertex program span");
        return nil;
    }
    _tokens = [NSData dataWithBytes:tokens length:length * 16];
    if (!_tokens) {
        program_error(error, @"Cannot snapshot native vertex program");
        return nil;
    }
    uint32_t words[NV2A_METAL_VP_SLOTS * 4];
    [_tokens getBytes:words length:_tokens.length];
    NV2AMetalProgramInstruction decoded[NV2A_METAL_VP_SLOTS];
    if (!decode_program(words, length, decoded, &_slots, error))
        return nil;
    _faultFreeReadOnlyAccess =
        readonly_fault_free_access(decoded, _slots, NULL);
    for (NSUInteger i = 0; i < _slots; i++) {
        const NV2AMetalProgramInstruction *op = &decoded[i];
        BOOL selected = op->output_mux ? op->ilu != NV2AMetalILUNop :
                                         (op->mac != NV2AMetalMACNop &&
                                          op->mac != NV2AMetalMACArl);
        _mayWriteConstants |=
            selected && op->output_mask && !(op->output_register & 256u);
    }
    _instructions = [NSData dataWithBytes:decoded
                                   length:_slots * sizeof(decoded[0])];
    if (!_instructions) {
        program_error(error, @"Cannot retain decoded vertex instructions");
        return nil;
    }
    return self;
}
@end

BOOL nv2a_metal_writable_validate_uniforms(
    const NV2AMetalProgramUniforms *uniforms, NSError **error)
{
    return program_uniforms_valid(uniforms) ||
           program_error(error, @"Invalid vertex uniforms");
}

BOOL nv2a_metal_writable_validate(const uint32_t *tokens, NSUInteger length,
                                  const NV2AMetalProgramUniforms *uniforms,
                                  NSError **error)
{
    NV2AMetalProgramInstruction decoded[NV2A_METAL_VP_SLOTS];
    NSUInteger slots;
    if (!nv2a_metal_writable_validate_uniforms(uniforms, error))
        return NO;
    return decode_program(tokens, length, decoded, &slots, error);
}

BOOL nv2a_metal_writable_validate_context(const uint32_t *tokens,
                                          NSUInteger length, NSError **error)
{
    NV2AMetalProgramInstruction decoded[NV2A_METAL_VP_SLOTS];
    NSUInteger slots;
    return decode_program(tokens, length, decoded, &slots, error);
}

@interface NV2AMetalWritableResult ()
- (instancetype)initWithContext:(const NV2AMetalWritableContext *)context
                      registers:(id<MTLBuffer>)registers
                       vertices:(id<MTLBuffer>)vertices
                          count:(NSUInteger)count;
@end
@implementation NV2AMetalWritableResult
- (instancetype)initWithContext:(const NV2AMetalWritableContext *)context
                      registers:(id<MTLBuffer>)registers
                       vertices:(id<MTLBuffer>)vertices
                          count:(NSUInteger)count
{
    self = [super init];
    if (self) {
        _constants = [NSData dataWithBytes:context->constants
                                    length:sizeof(context->constants)];
        _written = [NSData dataWithBytes:context->dirty
                                  length:sizeof(context->dirty)];
        _registers = registers;
        _vertices = vertices;
        _vertexCount = count;
    }
    return self;
}
@end
@interface NV2AMetalWritableEncoding ()
@property(nonatomic, readonly, nullable) id<MTLBuffer> serialContext;
- (BOOL)belongsToRecording:(NV2AMetalCommands *)commands;
- (instancetype)initRaw:(id<MTLBuffer>)raw
               vertices:(id<MTLBuffer>)vertices
                context:(id<MTLBuffer>)context
             parameters:(const NV2AMetalWritableParameters *)parameters
                compact:(BOOL)compact
      faultFreeReadOnly:(BOOL)faultFreeReadOnly
               commands:(NV2AMetalCommands *)commands;
@end
@implementation NV2AMetalWritableEncoding {
    id<MTLBuffer> _raw, _vertices, _context;
    NSData *_constants;
    NSUInteger _count;
    BOOL _writeEnable, _compact, _faultFreeReadOnly;
    __weak NV2AMetalCommands *_owner;
    uint64_t _recordingSerial;
}
- (instancetype)initRaw:(id<MTLBuffer>)raw
               vertices:(id<MTLBuffer>)vertices
                context:(id<MTLBuffer>)context
             parameters:(const NV2AMetalWritableParameters *)parameters
                compact:(BOOL)compact
      faultFreeReadOnly:(BOOL)faultFreeReadOnly
               commands:(NV2AMetalCommands *)commands
{
    self = [super init];
    if (self) {
        _raw = raw;
        _vertices = vertices;
        _context = context;
        _constants =
            [NSData dataWithBytes:parameters->common.constants
                           length:sizeof(parameters->common.constants)];
        _count = parameters->common.vertex_count;
        _writeEnable = parameters->write_enable;
        _compact = compact;
        _faultFreeReadOnly = faultFreeReadOnly && !_writeEnable && _compact;
        _owner = _writeEnable || _faultFreeReadOnly ? commands : nil;
        _recordingSerial = _owner ? commands.recordingSerial : 0;
    }
    return self;
}
- (id<MTLBuffer>)serialContext
{
    return _writeEnable ? _context : nil;
}
- (BOOL)belongsToRecording:(NV2AMetalCommands *)commands
{
    return commands && commands == _owner && commands.commandBuffer &&
           commands.recordingSerial == _recordingSerial;
}
- (NV2AMetalWritableResult *)pendingReadOnlyResultForCommands:
                                 (NV2AMetalCommands *)commands
                                                        error:(NSError **)error
{
    if (!_faultFreeReadOnly || ![self belongsToRecording:commands]) {
        program_error(error,
                      @"Pending readonly output needs a proven live recording");
        return nil;
    }
    NV2AMetalWritableContext context = { 0 };
    memcpy(context.constants, _constants.bytes, sizeof(context.constants));
    return [[NV2AMetalWritableResult alloc] initWithContext:&context
                                                  registers:nil
                                                   vertices:_vertices
                                                      count:_count];
}
- (NV2AMetalWritableResult *)resolveWithError:(NSError **)error
{
    NV2AMetalWritableContext readonlyContext = { 0 };
    const NV2AMetalWritableContext *snapshot = _context.contents;
    if (!_writeEnable) {
        const NV2AMetalProgramOutput *outputs = _raw.contents;
        NSUInteger faultCount = _compact ? 1 : _count;
        for (NSUInteger i = 0; i < faultCount; i++) {
            uint32_t fault = _compact ? ((const uint32_t *)_raw.contents)[i] :
                                        outputs[i].fault;
            if (fault) {
                program_error(error, @"Native writable-vertex address fault");
                return nil;
            }
        }
        memcpy(readonlyContext.constants, _constants.bytes,
               sizeof(readonlyContext.constants));
        snapshot = &readonlyContext;
    }
    if (snapshot->fault) {
        program_error(error, @"Native writable-vertex address fault");
        return nil;
    }
    for (unsigned row = 0; row < 192; row++) {
        if (snapshot->dirty[row] > 1) {
            program_error(error, @"Invalid writable-vertex context write flag");
            return nil;
        }
    }
    return
        [[NV2AMetalWritableResult alloc] initWithContext:snapshot
                                               registers:_compact ? nil : _raw
                                                vertices:_vertices
                                                   count:_count];
}
@end

/* Device-local, immutable token identity. Hash every declared byte, including
 * trailing slots after END; decoding still stops at the first END. */
@interface NV2AMetalProgramKey : NSObject <NSCopying>
@property(nonatomic, readonly) NSData *tokens;
- (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)length;
@end
@implementation NV2AMetalProgramKey {
    NSUInteger _hash;
}
- (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)length
{
    self = [super init];
    if (self) {
        _tokens = [NSData dataWithBytes:bytes length:length];
        if (!_tokens)
            return nil;
        const uint8_t *data = _tokens.bytes;
        uint64_t hash = UINT64_C(14695981039346656037);
        for (NSUInteger i = 0; i < length; i++)
            hash = (hash ^ data[i]) * UINT64_C(1099511628211);
        _hash = (NSUInteger)hash;
    }
    return self;
}
- (NSUInteger)hash
{
    return _hash;
}
- (BOOL)isEqual:(id)object
{
    return object == self ||
           ([object isKindOfClass:NV2AMetalProgramKey.class] &&
            [_tokens isEqualToData:((NV2AMetalProgramKey *)object).tokens]);
}
- (id)copyWithZone:(NSZone *)zone
{
    (void)zone;
    return self;
}
@end

@interface NV2AMetalDecodedProgram : NSObject
@property(nonatomic, readonly) NSData *tokens;
@property(nonatomic, readonly) id<MTLBuffer> buffer;
@property(nonatomic, readonly) NSUInteger slots;
/* Mutable publication metadata is protected by @synchronized(entry). */
@property(nonatomic) unsigned readonlyUses;
@property(nonatomic) BOOL specializationQueued, specializationFinished;
@property(nonatomic) NSArray<id<MTLComputePipelineState>> *specializedPipelines;
@property(nonatomic) NSError *specializationError;
- (instancetype)initWithTokens:(NSData *)tokens
                        buffer:(id<MTLBuffer>)buffer
                         slots:(NSUInteger)slots;
@end
@implementation NV2AMetalDecodedProgram
- (instancetype)initWithTokens:(NSData *)tokens
                        buffer:(id<MTLBuffer>)buffer
                         slots:(NSUInteger)slots
{
    self = [super init];
    if (self) {
        _tokens = [tokens copy];
        _buffer = buffer;
        _slots = slots;
    }
    return self;
}
@end

@implementation NV2AMetalWritableProgram {
    NV2AMetalCommands *_commands;
    id<MTL4Compiler> _specializationCompiler;
    dispatch_queue_t _specializationQueue;
    id<MTLComputePipelineState> _pipeline, _readonlyPipeline, _rasterPipeline,
        _writableRasterPipeline, _writableRawPipeline, _readonlyRawPipeline;
    id<MTLComputePipelineState> _chainedRasterPipeline, _chainedRawPipeline;
    MTL4LibraryFunctionDescriptor *_writableRasterFunction;
    id<MTL4ArgumentTable> _arguments;
    NV2AMetalDecodedProgram *_decodedProgram;
    NV2AMetalLRUCache<NV2AMetalProgramKey *, NV2AMetalDecodedProgram *>
        *_programs;
    /* Cache diagnostics; not emulated registers or persistent state. */
    uint64_t _programDecodeCount, _programBufferRequests, _programFastHits;
    uint64_t _programMetadataUploads;
    uint64_t _specializationAttempts, _specializationSuccesses;
    uint64_t _specializationFailures, _specializationPending;
    uint64_t _specializedDispatches, _interpreterDispatches;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    _commands = [[NV2AMetalCommands alloc] initWithDevice:device error:error];
    if (!_commands)
        return nil;
    id<MTL4Compiler> compiler =
        [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                    error:error];
    if (!compiler)
        return nil;
    MTL4LibraryDescriptor *libraryDescriptor = [MTL4LibraryDescriptor new];
    libraryDescriptor.source = @(metal_shader_source);
    libraryDescriptor.options = [MTLCompileOptions new];
    libraryDescriptor.options.languageVersion = MTLLanguageVersion4_0;
    libraryDescriptor.options.mathMode = MTLMathModeSafe;
    libraryDescriptor.options.mathFloatingPointFunctions =
        MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> library =
        [compiler newLibraryWithDescriptor:libraryDescriptor error:error];
    if (!library)
        return nil;
    MTL4LibraryFunctionDescriptor *function =
        [MTL4LibraryFunctionDescriptor new];
    function.library = library;
    function.name = @"nv2a_writable_program";
    MTL4ComputePipelineDescriptor *descriptor =
        [MTL4ComputePipelineDescriptor new];
    descriptor.computeFunctionDescriptor = function;
    _pipeline = [compiler newComputePipelineStateWithDescriptor:descriptor
                                            compilerTaskOptions:nil
                                                          error:error];
    if (!_pipeline)
        return nil;
    _writableRasterFunction = [MTL4LibraryFunctionDescriptor new];
    _writableRasterFunction.library = library;
    _writableRasterFunction.name = @"nv2a_writable_raster_program";
    function.name = @"nv2a_readonly_program";
    descriptor.computeFunctionDescriptor = function;
    _readonlyPipeline =
        [compiler newComputePipelineStateWithDescriptor:descriptor
                                    compilerTaskOptions:nil
                                                  error:error];
    if (!_readonlyPipeline)
        return nil;
    function.name = @"nv2a_readonly_raster_program";
    descriptor.computeFunctionDescriptor = function;
    _rasterPipeline = [compiler newComputePipelineStateWithDescriptor:descriptor
                                                  compilerTaskOptions:nil
                                                                error:error];
    if (!_rasterPipeline)
        return nil;
    MTL4ArgumentTableDescriptor *arguments = [MTL4ArgumentTableDescriptor new];
    arguments.maxBufferBindCount = 7;
    arguments.initializeBindings = YES;
    _arguments = [device newArgumentTableWithDescriptor:arguments error:error];
    /* 64 * 136 * (16 token + 56 decoded) bytes <= 612 KiB payload.
     * This excludes native pipeline objects. Each entry holds at most three;
     * at most two compile jobs retain evicted entries. Commands independently
     * retain buffers/pipelines until GPU completion. */
    _programs = [[NV2AMetalLRUCache alloc] initWithCapacity:64];
    _specializationCompiler = compiler;
    _specializationQueue =
        dispatch_queue_create("org.xemu.metal4.readonly-compile",
                              dispatch_queue_attr_make_with_qos_class(
                                  DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    return _arguments && _programs && _specializationQueue ? self : nil;
}
/* Only decoded CPU-uploaded instructions become source constants. Input
 * values,constants,access policy and raster uniforms are never specialized. */
- (NSArray<id<MTLComputePipelineState>> *)
    compileReadonlyProgram:(NV2AMetalDecodedProgram *)program
                     error:(NSError **)error
{
    NSMutableString *source =
        [NSMutableString stringWithUTF8String:metal_shader_source];
    [source appendString:@"\nconstant NV2AMetalProgramInstruction "
                         @"nv2a_specialized_ops[] = {\n"];
    const NV2AMetalProgramInstruction *ops = program.buffer.contents;
    for (NSUInteger slot = 0; slot < program.slots; slot++) {
        NV2AMetalProgramInstruction op = ops[slot];
        [source appendFormat:@"{%uu,%uu,%uu,%uu,{%uu,%uu,%uu},%uu,%uu,%uu,%uu,%"
                             @"uu,%uu,%uu},\n",
                             op.mac, op.ilu, op.constant_index,
                             op.attribute_index, op.source[0], op.source[1],
                             op.source[2], op.mac_mask, op.ilu_mask,
                             op.output_mask, op.output_register, op.output_mux,
                             op.temp_register, op.relative];
    }
    [source appendString:
                @"};\nstruct NV2AMetalReadonlySpecialized {\n"
                 "static void execute(constant NV2AMetalProgramInstruction *,"
                 "constant NV2AMetalProgramUniforms &u,"
                 "device const NV2AMetalProgramInput &input,"
                 "thread VPReadOnlyRegisters &r) {\n"];
    for (NSUInteger slot = 0; slot < program.slots; slot++)
        [source
            appendFormat:
                @"if (!r.fault) "
                @"writable_step(nv2a_specialized_ops[%lu],u,input,r,false);\n",
                (unsigned long)slot];
    [source appendString:@"}};\n"
                          "NV2A_METAL_READONLY_ENTRY(nv2a_readonly_specialized,"
                          "false,NV2AMetalReadonlySpecialized)\n"
                          "NV2A_METAL_READONLY_ENTRY(nv2a_readonly_raster_"
                          "specialized,true,NV2AMetalReadonlySpecialized)\n"
                          "NV2A_METAL_READONLY_RAW_ENTRY(nv2a_readonly_raw_"
                          "specialized,NV2AMetalReadonlySpecialized)\n"];
    MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
    ld.source = source;
    ld.options = [MTLCompileOptions new];
    ld.options.languageVersion = MTLLanguageVersion4_0;
    ld.options.mathMode = MTLMathModeSafe;
    ld.options.mathFloatingPointFunctions =
        MTLMathFloatingPointFunctionsPrecise;
    id<MTLLibrary> library =
        [_specializationCompiler newLibraryWithDescriptor:ld error:error];
    if (!library)
        return nil;
    NSMutableArray *pipelines = [NSMutableArray new];
    for (NSString *name in @[
             @"nv2a_readonly_specialized", @"nv2a_readonly_raster_specialized",
             @"nv2a_readonly_raw_specialized"
         ]) {
        MTL4LibraryFunctionDescriptor *function =
            [MTL4LibraryFunctionDescriptor new];
        function.library = library;
        function.name = name;
        MTL4ComputePipelineDescriptor *descriptor =
            [MTL4ComputePipelineDescriptor new];
        descriptor.computeFunctionDescriptor = function;
        id<MTLComputePipelineState> pipeline = [_specializationCompiler
            newComputePipelineStateWithDescriptor:descriptor
                              compilerTaskOptions:nil
                                            error:error];
        if (!pipeline)
            return nil;
        [pipelines addObject:pipeline];
    }
    return [pipelines copy];
}
- (id<MTLComputePipelineState>)readonlyPipelineForProgram:
                                   (NV2AMetalDecodedProgram *)program
                                                  compact:(BOOL)compact
                                                  discard:(BOOL)discard
{
    @synchronized(program) {
        if (program.specializedPipelines) {
            _specializedDispatches++;
            return program.specializedPipelines[discard ? 2 : compact ? 1 : 0];
        }
        if (program.readonlyUses < 4)
            program.readonlyUses++;
    }
    /* Cold programs use the general GPU interpreter. At most two jobs retain
     * entries outside the64-entry LRU; compilation never blocks a draw. */
    @synchronized(self) {
        @synchronized(program) {
            if (program.readonlyUses == 4 && !program.specializationQueued &&
                !program.specializationFinished && _specializationPending < 2) {
                program.specializationQueued = YES;
                _specializationPending++;
                _specializationAttempts++;
                dispatch_async(_specializationQueue, ^{
                  @autoreleasepool {
                      NSError *error = nil;
                      NSArray *pipelines = [self compileReadonlyProgram:program
                                                                  error:&error];
                      @synchronized(program) {
                          program.specializedPipelines = pipelines;
                          program.specializationError = error;
                          program.specializationFinished = YES;
                      }
                      @synchronized(self) {
                          _specializationPending--;
                          if (pipelines)
                              _specializationSuccesses++;
                          else
                              _specializationFailures++;
                      }
                  }
                });
            }
        }
    }
    _interpreterDispatches++;
    return discard ? _readonlyRawPipeline :
           compact ? _rasterPipeline :
                     _readonlyPipeline;
}
- (NV2AMetalDecodedProgram *)programForTokens:(const uint32_t *)tokens
                                       length:(NSUInteger)length
                                        error:(NSError **)error
{
    return [self programForTokens:tokens
                           length:length
                 validatedProgram:nil
                            error:error];
}
- (NV2AMetalDecodedProgram *)programForTokens:(const uint32_t *)tokens
                                       length:(NSUInteger)length
                             validatedProgram:
                                 (NV2AMetalValidatedProgram *)validated
                                        error:(NSError **)error
{
    if (!tokens || !length || length > NV2A_METAL_VP_SLOTS) {
        program_error(error, @"Invalid NV2A vertex program span");
        return nil;
    }
    NSUInteger bytes = length * 4 * sizeof(*tokens);
    if (validated &&
        (![validated isMemberOfClass:NV2AMetalValidatedProgram.class] ||
         validated.tokens.length != bytes || !validated.slots ||
         validated.slots > length ||
         validated.instructions.length !=
             validated.slots * sizeof(NV2AMetalProgramInstruction) ||
         memcmp(validated.tokens.bytes, tokens, bytes))) {
        program_error(error, @"Invalid validated vertex program metadata");
        return nil;
    }
    /* Repeated A/A remains allocation-free for token/cache bookkeeping.
     * The last entry is also the newest LRU entry; A/B/A uses full-byte lookup.
     */
    if (_decodedProgram.tokens.length == bytes &&
        !memcmp(_decodedProgram.tokens.bytes, tokens, bytes)) {
        _programFastHits++;
        return _decodedProgram;
    }
    NV2AMetalProgramKey *key =
        [[NV2AMetalProgramKey alloc] initWithBytes:tokens length:bytes];
    if (!key) {
        program_error(error, @"Cannot snapshot native vertex program");
        return nil;
    }
    NV2AMetalDecodedProgram *cached = _programs[key];
    if (cached) {
        _decodedProgram = cached;
        return cached;
    }
    NSData *snapshot = key.tokens;
    NV2AMetalProgramInstruction decoded[NV2A_METAL_VP_SLOTS];
    NSUInteger slots = 0;
    const void *instructions;
    if (validated) {
        slots = validated.slots;
        instructions = validated.instructions.bytes;
        _programMetadataUploads++;
    } else {
        uint32_t words[NV2A_METAL_VP_SLOTS * 4];
        [snapshot getBytes:words length:bytes];
        _programDecodeCount++;
        if (!decode_program(words, length, decoded, &slots, error))
            return nil;
        instructions = decoded;
    }
    _programBufferRequests++;
    id<MTLBuffer> buffer =
        [_commands.device newBufferWithBytes:instructions
                                      length:slots * sizeof(decoded[0])
                                     options:MTLResourceStorageModeShared];
    if (!buffer) {
        program_error(error, @"Cannot allocate native writable-vertex buffers");
        return nil;
    }
    NV2AMetalDecodedProgram *program =
        [[NV2AMetalDecodedProgram alloc] initWithTokens:snapshot
                                                 buffer:buffer
                                                  slots:slots];
    if (!program) {
        program_error(error, @"Cannot cache native vertex program");
        return nil;
    }
    _programs[key] = program;
    _decodedProgram = program;
    return program;
}
- (NV2AMetalWritableResult *)executeTokens:(const uint32_t *)tokens
                                    length:(NSUInteger)length
                                  uniforms:
                                      (const NV2AMetalProgramUniforms *)uniforms
                                attributes:(NSData *)attributes
                                     count:(NSUInteger)count
                                    access:(unsigned)access
                               writeEnable:(BOOL)writeEnable
                                     error:(NSError **)error
{
    if (count >
            _commands.device.maxBufferLength / sizeof(NV2AMetalProgramInput) ||
        attributes.length != count * sizeof(NV2AMetalProgramInput)) {
        program_error(error, @"Invalid native writable-vertex input data");
        return nil;
    }
    NV2AMetalProgramInput empty = { 0 };
    id<MTLBuffer> inputs = [_commands.device
        newBufferWithBytes:count ? attributes.bytes : &empty
                    length:count ? attributes.length : sizeof(empty)
                   options:MTLResourceStorageModeShared];
    if (!inputs) {
        program_error(error, @"Cannot allocate writable vertex inputs");
        return nil;
    }
    return [self executeTokens:tokens
                        length:length
                      uniforms:uniforms
               attributeBuffer:inputs
                         first:0
                         count:count
                        access:access
                   writeEnable:writeEnable
                         error:error];
}
- (NV2AMetalWritableResult *)executeTokens:(const uint32_t *)tokens
                                    length:(NSUInteger)length
                                  uniforms:
                                      (const NV2AMetalProgramUniforms *)uniforms
                           attributeBuffer:(id<MTLBuffer>)attributes
                                     first:(NSUInteger)first
                                     count:(NSUInteger)count
                                    access:(unsigned)access
                               writeEnable:(BOOL)writeEnable
                                     error:(NSError **)error
{
    return [self executeTokens:tokens
                        length:length
                      uniforms:uniforms
               attributeBuffer:attributes
                         first:first
                         count:count
                        access:access
                   writeEnable:writeEnable
                     rasterize:YES
                         error:error];
}
- (NV2AMetalWritableResult *)executeTokens:(const uint32_t *)tokens
                                    length:(NSUInteger)length
                                  uniforms:
                                      (const NV2AMetalProgramUniforms *)uniforms
                           attributeBuffer:(id<MTLBuffer>)attributes
                                     first:(NSUInteger)first
                                     count:(NSUInteger)count
                                    access:(unsigned)access
                               writeEnable:(BOOL)writeEnable
                                 rasterize:(BOOL)rasterize
                                     error:(NSError **)error
{
    return [self executeTokens:tokens
                        length:length
              validatedProgram:nil
                      uniforms:uniforms
               attributeBuffer:attributes
                         first:first
                         count:count
                        access:access
                   writeEnable:writeEnable
                     rasterize:rasterize
              compactRegisters:NO
                         error:error];
}
- (NV2AMetalWritableResult *)
     executeProgram:(NV2AMetalValidatedProgram *)program
           uniforms:(const NV2AMetalProgramUniforms *)uniforms
    attributeBuffer:(id<MTLBuffer>)attributes
              first:(NSUInteger)first
              count:(NSUInteger)count
             access:(unsigned)access
        writeEnable:(BOOL)writeEnable
          rasterize:(BOOL)rasterize
              error:(NSError **)error
{
    return [self executeProgram:program
                       uniforms:uniforms
                attributeBuffer:attributes
                          first:first
                          count:count
                         access:access
                    writeEnable:writeEnable
                      rasterize:rasterize
               compactRegisters:NO
                          error:error];
}
- (NV2AMetalWritableResult *)
      executeProgram:(NV2AMetalValidatedProgram *)program
            uniforms:(const NV2AMetalProgramUniforms *)uniforms
     attributeBuffer:(id<MTLBuffer>)attributes
               first:(NSUInteger)first
               count:(NSUInteger)count
              access:(unsigned)access
         writeEnable:(BOOL)writeEnable
           rasterize:(BOOL)rasterize
    compactRegisters:(BOOL)compact
               error:(NSError **)error
{
    if (![program isMemberOfClass:NV2AMetalValidatedProgram.class]) {
        program_error(error, @"Missing validated vertex program");
        return nil;
    }
    return [self executeTokens:program.tokens.bytes
                        length:program.tokens.length / 16
              validatedProgram:program
                      uniforms:uniforms
               attributeBuffer:attributes
                         first:first
                         count:count
                        access:access
                   writeEnable:writeEnable
                     rasterize:rasterize
              compactRegisters:compact
                         error:error];
}
- (NV2AMetalWritableResult *)
       executeTokens:(const uint32_t *)tokens
              length:(NSUInteger)length
    validatedProgram:(NV2AMetalValidatedProgram *)validated
            uniforms:(const NV2AMetalProgramUniforms *)uniforms
     attributeBuffer:(id<MTLBuffer>)attributes
               first:(NSUInteger)first
               count:(NSUInteger)count
              access:(unsigned)access
         writeEnable:(BOOL)writeEnable
           rasterize:(BOOL)rasterize
    compactRegisters:(BOOL)compact
               error:(NSError **)error
{
    if (![_commands beginWithError:error])
        return nil;
    NV2AMetalWritableEncoding *encoded = [self encodeTokens:tokens
                                                     length:length
                                           validatedProgram:validated
                                                   uniforms:uniforms
                                            attributeBuffer:attributes
                                                      first:first
                                                      count:count
                                                     access:access
                                                writeEnable:writeEnable
                                                  rasterize:rasterize
                                           compactRegisters:compact
                                                   previous:nil
                                                   commands:_commands
                                                      error:error];
    if (!encoded || ![_commands submitWithError:error]) {
        [_commands cancel];
        return nil;
    }
    if (![_commands waitUntilIdleWithError:error])
        return nil;
    return [encoded resolveWithError:error];
}
- (NV2AMetalWritableEncoding *)
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
              error:(NSError **)error
{
    return [self encodeTokens:tokens
                       length:length
                     uniforms:uniforms
              attributeBuffer:attributes
                        first:first
                        count:count
                       access:access
                  writeEnable:writeEnable
                    rasterize:rasterize
             compactRegisters:NO
                     commands:commands
                        error:error];
}
- (NV2AMetalWritableEncoding *)
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
               error:(NSError **)error
{
    return [self encodeTokens:tokens
                       length:length
             validatedProgram:nil
                     uniforms:uniforms
              attributeBuffer:attributes
                        first:first
                        count:count
                       access:access
                  writeEnable:writeEnable
                    rasterize:rasterize
             compactRegisters:compact
                      previous:nil
                     commands:commands
                        error:error];
}
- (NV2AMetalWritableEncoding *)
       encodeProgram:(NV2AMetalValidatedProgram *)program
            uniforms:(const NV2AMetalProgramUniforms *)uniforms
     attributeBuffer:(id<MTLBuffer>)attributes
               first:(NSUInteger)first
               count:(NSUInteger)count
              access:(unsigned)access
         writeEnable:(BOOL)writeEnable
           rasterize:(BOOL)rasterize
    compactRegisters:(BOOL)compact
            commands:(NV2AMetalCommands *)commands
               error:(NSError **)error
{
    if (![program isMemberOfClass:NV2AMetalValidatedProgram.class]) {
        program_error(error, @"Missing validated vertex program");
        return nil;
    }
    return [self encodeTokens:program.tokens.bytes
                       length:program.tokens.length / 16
             validatedProgram:program
                     uniforms:uniforms
              attributeBuffer:attributes
                        first:first
                        count:count
                       access:access
                  writeEnable:writeEnable
                    rasterize:rasterize
             compactRegisters:compact
                      previous:nil
                     commands:commands
                        error:error];
}
- (NV2AMetalWritableEncoding *)
    encodeSerialProgram:(NV2AMetalValidatedProgram *)program
               uniforms:(const NV2AMetalProgramUniforms *)uniforms
        attributeBuffer:(id<MTLBuffer>)attributes
                  first:(NSUInteger)first
                  count:(NSUInteger)count
                 access:(unsigned)access
              rasterize:(BOOL)rasterize
               previous:(NV2AMetalWritableEncoding *)previous
               commands:(NV2AMetalCommands *)commands
                  error:(NSError **)error
{
    if (![program isMemberOfClass:NV2AMetalValidatedProgram.class] ||
        (previous && (!previous.serialContext ||
                      ![previous belongsToRecording:commands]))) {
        program_error(error, @"Invalid serial writable context predecessor");
        return nil;
    }
    return [self encodeTokens:program.tokens.bytes
                       length:program.tokens.length / 16
             validatedProgram:program
                     uniforms:uniforms
              attributeBuffer:attributes
                        first:first
                        count:count
                       access:access
                  writeEnable:YES
                    rasterize:rasterize
             compactRegisters:YES
                     previous:previous
                     commands:commands
                        error:error];
}
- (NV2AMetalWritableEncoding *)
        encodeTokens:(const uint32_t *)tokens
              length:(NSUInteger)length
    validatedProgram:(NV2AMetalValidatedProgram *)validated
            uniforms:(const NV2AMetalProgramUniforms *)uniforms
     attributeBuffer:(id<MTLBuffer>)attributes
               first:(NSUInteger)first
               count:(NSUInteger)count
              access:(unsigned)access
         writeEnable:(BOOL)writeEnable
           rasterize:(BOOL)rasterize
    compactRegisters:(BOOL)compact
            previous:(NV2AMetalWritableEncoding *)previous
            commands:(NV2AMetalCommands *)commands
               error:(NSError **)error
{
    id<MTLDevice> device = commands.device;
    if ((compact != YES && compact != NO) || !commands.commandBuffer ||
        device != _commands.device || access > 1 ||
        (writeEnable != YES && writeEnable != NO) ||
        (rasterize != YES && rasterize != NO) || !uniforms ||
        (rasterize && !program_uniforms_valid(uniforms)) || count > UINT_MAX ||
        count > device.maxBufferLength / sizeof(NV2AMetalProgramInput) ||
        count > device.maxBufferLength / sizeof(NV2AMetalProgramOutput) ||
        count > device.maxBufferLength / sizeof(NV2AMetalVertex) ||
        !attributes || attributes.device != device ||
        first > attributes.length / sizeof(NV2AMetalProgramInput) ||
        count > attributes.length / sizeof(NV2AMetalProgramInput) - first) {
        program_error(error, @"Invalid native writable-vertex input");
        return nil;
    }
    NV2AMetalDecodedProgram *decoded = [self programForTokens:tokens
                                                       length:length
                                             validatedProgram:validated
                                                        error:error];
    if (!decoded)
        return nil;
    BOOL discard = compact && !rasterize;
    id<MTLComputePipelineState> chainedPipeline = nil;
    if (previous) {
        chainedPipeline =
            discard ? _chainedRawPipeline : _chainedRasterPipeline;
        if (!chainedPipeline) {
            MTL4LibraryFunctionDescriptor *function =
                [MTL4LibraryFunctionDescriptor new];
            function.library = _writableRasterFunction.library;
            function.name = discard ? @"nv2a_writable_chained_raw_program" :
                                      @"nv2a_writable_chained_raster_program";
            MTL4ComputePipelineDescriptor *descriptor =
                [MTL4ComputePipelineDescriptor new];
            descriptor.computeFunctionDescriptor = function;
            chainedPipeline = [_specializationCompiler
                newComputePipelineStateWithDescriptor:descriptor
                                  compilerTaskOptions:nil
                                                error:error];
            if (!chainedPipeline)
                return nil;
            if (discard)
                _chainedRawPipeline = chainedPipeline;
            else
                _chainedRasterPipeline = chainedPipeline;
        }
    }
    if (discard) {
        id<MTLComputePipelineState> pipeline =
            writeEnable ? _writableRawPipeline : _readonlyRawPipeline;
        if (!pipeline) {
            MTL4LibraryFunctionDescriptor *function =
                [MTL4LibraryFunctionDescriptor new];
            function.library = _writableRasterFunction.library;
            function.name = writeEnable ? @"nv2a_writable_raw_program" :
                                          @"nv2a_readonly_raw_program";
            MTL4ComputePipelineDescriptor *descriptor =
                [MTL4ComputePipelineDescriptor new];
            descriptor.computeFunctionDescriptor = function;
            pipeline = [_specializationCompiler
                newComputePipelineStateWithDescriptor:descriptor
                                  compilerTaskOptions:nil
                                                error:error];
            if (!pipeline)
                return nil;
            if (writeEnable)
                _writableRawPipeline = pipeline;
            else
                _readonlyRawPipeline = pipeline;
        }
    }
    if (!discard && writeEnable && compact && !_writableRasterPipeline) {
        MTL4ComputePipelineDescriptor *descriptor =
            [MTL4ComputePipelineDescriptor new];
        descriptor.computeFunctionDescriptor = _writableRasterFunction;
        _writableRasterPipeline = [_specializationCompiler
            newComputePipelineStateWithDescriptor:descriptor
                              compilerTaskOptions:nil
                                            error:error];
        if (!_writableRasterPipeline)
            return nil;
    }
    NV2AMetalWritableParameters parameters = { 0 };
    parameters.common = *uniforms;
    parameters.common.vertex_count = (unsigned)count;
    parameters.common.program_length = (unsigned)decoded.slots;
    parameters.full_access = access;
    parameters.write_enable = writeEnable;
    parameters.rasterize = rasterize;
    id<MTLBuffer> inputs = attributes;
    id<MTLBuffer> raw =
        compact && writeEnable ?
            nil :
            [device
                newBufferWithLength:compact ? sizeof(uint32_t) :
                                              MAX(count, 1u) *
                                                  sizeof(NV2AMetalProgramOutput)
                            options:MTLResourceStorageModeShared];
    id<MTLBuffer> vertices =
        discard ?
            nil :
            [device newBufferWithLength:MAX(count, 1u) * sizeof(NV2AMetalVertex)
                                options:MTLResourceStorageModeShared];
    NSUInteger paramsOffset = 0;
    id<MTLBuffer> params = [commands uploadBytes:&parameters
                                          length:sizeof(parameters)
                                          offset:&paramsOffset
                                           error:error];
    if (!params) {
        return nil;
    }
    id<MTLBuffer> program = decoded.buffer;
    id<MTLBuffer> context =
        writeEnable ?
            [device newBufferWithLength:sizeof(NV2AMetalWritableContext)
                                options:MTLResourceStorageModeShared] :
            nil;
    if (!inputs || ((!compact || !writeEnable) && !raw) ||
        (!discard && !vertices) || !program || (writeEnable && !context)) {
        program_error(error, @"Cannot allocate native writable-vertex buffers");
        return nil;
    }
    if (compact && raw) {
        uint32_t zero = 0;
        memcpy(raw.contents, &zero, sizeof(zero));
    }
    id<MTLBuffer> buffers[] = { inputs, raw, vertices, params, program };
    for (unsigned i = 0; i < 5; i++) {
        if (i != 3 && buffers[i] &&
            ![commands addResource:buffers[i] error:error]) {
            return nil;
        }
        NSUInteger offset = i == 3 ? paramsOffset :
                            i == 0 && count ?
                                     first * sizeof(NV2AMetalProgramInput) :
                                     0;
        [_arguments setAddress:buffers[i].gpuAddress + offset atIndex:i];
    }
    if (context && ![commands addResource:context error:error])
        return nil;
    [_arguments setAddress:context.gpuAddress atIndex:5];
    id<MTLBuffer> prior = previous.serialContext;
    if (prior && ![commands addResource:prior error:error])
        return nil;
    [_arguments setAddress:prior.gpuAddress atIndex:6];
    id<MTLComputePipelineState> pipeline =
        writeEnable || !count ?
            (writeEnable ? (discard ? _writableRawPipeline :
                            compact ? _writableRasterPipeline :
                                      _pipeline) :
             discard     ? _readonlyRawPipeline :
             compact     ? _rasterPipeline :
                           _readonlyPipeline) :
            [self readonlyPipelineForProgram:decoded
                                     compact:compact
                                     discard:discard];
    if (chainedPipeline)
        pipeline = chainedPipeline;
    if (![commands keepAlive:_arguments error:error] ||
        ![commands keepAlive:pipeline error:error])
        return nil;
    id<MTL4ComputeCommandEncoder> encoder =
        [commands.commandBuffer computeCommandEncoder];
    if (!encoder) {
        program_error(error, @"Cannot encode native writable-vertex program");
        return nil;
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:MTLStageDispatch
                   visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder setArgumentTable:_arguments];
    [encoder setComputePipelineState:pipeline];
    NSUInteger threads = writeEnable ? 1 : MAX(count, 1u);
    NSUInteger width =
        writeEnable ? 1 : MIN(threads, pipeline.threadExecutionWidth);
    [encoder dispatchThreads:MTLSizeMake(threads, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
    [encoder barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return [[NV2AMetalWritableEncoding alloc]
                  initRaw:raw
                 vertices:vertices
                  context:context
               parameters:&parameters
                  compact:compact
        faultFreeReadOnly:!writeEnable &&
                          [validated
                              hasFaultFreeReadOnlyAccess:access
                                               constants:&parameters.common
                                                              .constants[0][0]]
                 commands:commands];
}
@end
