#import "vertex-writable.h"
#import "vertex-fetch.h"
#import "lru-cache.h"
#include <limits.h>
#include <math.h>
#include <stddef.h>
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

static unsigned instruction_sources(const NV2AMetalProgramInstruction *op)
{
    unsigned sources = op->mac != NV2AMetalMACNop ? 1u : 0u;
    if (sources && op->mac != NV2AMetalMACMov && op->mac != NV2AMetalMACAdd &&
        op->mac != NV2AMetalMACArl)
        sources |= 2u;
    if (op->mac == NV2AMetalMACAdd || op->mac == NV2AMetalMACMad ||
        op->ilu != NV2AMetalILUNop)
        sources |= 4u;
    return sources;
}

/* Data dependencies of the masked writes in writable_step, vp_mac/vp_ilu
 * and vp_write. Operand apertures are checked separately, even when none of
 * an instruction's values reaches a destination. Bits3..0 denote XYZW. */
static unsigned
independent_constant_lanes(const NV2AMetalProgramInstruction *op,
                           unsigned source, unsigned mac, unsigned ilu)
{
    unsigned lanes[3] = { 0 };
    if (op->mac == NV2AMetalMACArl)
        lanes[0] = 8;
    else if (mac) {
        switch (op->mac) {
        case NV2AMetalMACMov:
            lanes[0] = mac;
            break;
        case NV2AMetalMACAdd:
            lanes[0] = lanes[2] = mac;
            break;
        case NV2AMetalMACDp3:
            lanes[0] = lanes[1] = 14;
            break;
        case NV2AMetalMACDph:
            lanes[0] = 14;
            lanes[1] = 15;
            break;
        case NV2AMetalMACDp4:
            lanes[0] = lanes[1] = 15;
            break;
        case NV2AMetalMACDst:
            lanes[0] = mac & 6;
            lanes[1] = mac & 5;
            break;
        default:
            lanes[0] = lanes[1] = mac;
            if (op->mac == NV2AMetalMACMad)
                lanes[2] = mac;
            break;
        }
    }
    if (op->ilu == NV2AMetalILUMov)
        lanes[2] |= ilu;
    else if (ilu && op->ilu >= NV2AMetalILURcp && op->ilu <= NV2AMetalILURsq)
        lanes[2] |= 8;
    else if ((ilu & 14) &&
             (op->ilu == NV2AMetalILUExp || op->ilu == NV2AMetalILULog))
        lanes[2] |= 8;
    else if (op->ilu == NV2AMetalILULit) {
        if (ilu & 4)
            lanes[2] |= 8;
        if (ilu & 2)
            lanes[2] |= 13;
    }
    unsigned result = 0;
    for (unsigned lane = 0; lane < 4; lane++)
        if (lanes[source] & (8u >> lane))
            result |= 8u >> ((op->source[source] >> (6 + 2 * lane)) & 3u);
    return result;
}

static unsigned independent_live_write(uint8_t *live, unsigned mask)
{
    unsigned result = *live & mask;
    *live &= ~mask;
    return result;
}

typedef struct NV2AMetalConstantRows {
    uint16_t low, high;
} NV2AMetalConstantRows;

static void independent_constant_reads(
    const NV2AMetalProgramInstruction *instructions, NSUInteger slots,
    const NV2AMetalConstantRows *constantRows, uint8_t readLanes[192])
{
    uint8_t temporaryLive[12] = { 0 }, outputLive[13], constantLive[192];
    /* Full raw snapshots publish every output component, not just raster
     * inputs. All final constants are observable, including untouched lanes. */
    memset(outputLive, 15, sizeof(outputLive));
    memset(constantLive, 15, sizeof(constantLive));
    while (slots) {
        const NV2AMetalProgramInstruction *op = &instructions[--slots];
        BOOL paired = op->mac != NV2AMetalMACNop && op->ilu != NV2AMetalILUNop;
        unsigned mac = 0, ilu = 0;
        /* Reverse writable_step's output/ILU/MAC destination order before
         * adding any operand reads. R12 and oPos share the same live mask. */
        if (op->mac != NV2AMetalMACNop && op->mac != NV2AMetalMACArl &&
            !(paired && op->temp_register == 1) && op->mac_mask) {
            uint8_t *live = op->temp_register == 12 ?
                                outputLive :
                                temporaryLive + op->temp_register;
            mac = independent_live_write(live, op->mac_mask);
        }
        if (op->ilu != NV2AMetalILUNop && op->ilu_mask) {
            unsigned reg = paired ? 1 : op->temp_register;
            uint8_t *live = reg == 12 ? outputLive : temporaryLive + reg;
            ilu = independent_live_write(live, op->ilu_mask);
        }
        BOOL macOutput = !op->output_mux && op->mac != NV2AMetalMACNop &&
                         op->mac != NV2AMetalMACArl;
        BOOL iluOutput = op->output_mux && op->ilu != NV2AMetalILUNop;
        if (op->output_mask && (macOutput || iluOutput)) {
            unsigned output = op->output_mask;
            BOOL vertex = (op->output_register & 256u) != 0;
            unsigned row = op->output_register & 255u;
            /* Fog writes/consumes the first popcount(mask) components. The
             * surviving subset can be noncontiguous after later overwrites. */
            if (vertex && row == 5)
                output = (15u << (4 - __builtin_popcount(output))) & 15u;
            unsigned needed = independent_live_write(
                (vertex ? outputLive : constantLive) + row, output);
            if (macOutput)
                mac |= needed;
            else
                ilu |= needed;
        }
        unsigned sources = instruction_sources(op);
        for (unsigned source = 0; source < 3; source++) {
            if (!(sources & (1u << source)))
                continue;
            unsigned lanes = independent_constant_lanes(op, source, mac, ilu);
            unsigned mux = op->source[source] & 3u;
            unsigned reg = (op->source[source] >> 2) & 15u;
            if (mux == 1) {
                if (reg == 12)
                    outputLive[0] |= lanes;
                else
                    temporaryLive[reg] |= lanes;
            } else if (mux == 3) {
                /* Incoming ARL, before this instruction's paired writes.
                 * The static forward proof checked the entire aperture. */
                NV2AMetalConstantRows rows = constantRows[slots];
                for (unsigned row = rows.low; row <= rows.high; row++) {
                    readLanes[row] |= lanes;
                    constantLive[row] |= lanes;
                }
            }
        }
    }
}

static BOOL valid_instruction(const NV2AMetalProgramInstruction *op,
                              const uint32_t *token, NSError **error)
{
    if (op->mac > NV2AMetalMACArl || op->ilu > NV2AMetalILULit) {
        return program_error(error, @"Invalid NV2A vertex-program opcode");
    }
    unsigned sources = instruction_sources(op);
    for (unsigned s = 0; s < 3; s++) {
        if (!(sources & (1u << s))) {
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
/* Conservative real intervals with integer endpoints. All accepted endpoints
 * lie within +/-2^24, where every integer is exactly representable by Float32.
 * Products are checked before narrowing.
 * Kelvin sum alignment has at least four fractional bits at this magnitude;
 * its truncation preserves integer bounds, even across four-term cancellation.
 * Final RZ packing also preserves accepted endpoints, including FTZ.
 * Zero-wins products accept exact zero-exponent operands, after all operand
 * aperture checks.
 * ARL's floor(x + .001f) maps each bounded interval back into itself.
 * Exact finite operands can additionally follow the shader's integer-bit
 * arithmetic below, without widening the interval limits. */
enum {
    ReadonlyProofPower = 24,
    ReadonlyProofLimit = 1 << ReadonlyProofPower,
};
_Static_assert(ReadonlyProofPower <= 24 && 4LL * ReadonlyProofLimit <= INT_MAX,
               "Integer bounds must be exact Float32; four-term sums must fit");
typedef struct NV2AMetalProofRange {
    int low, high;
    /* Optional nonzero-magnitude lower bound: |x| >= 2^(exponent-127).
     * Zero means unproven. Moves preserve it; arithmetic may discard it. */
    unsigned magnitudeExponent;
    /* Captured or exactly propagated finite Float32, or UINT32_MAX when
     * only the interval is known. */
    uint32_t exactBits;
} NV2AMetalProofRange;
/* Limit+1 are open ends in vp_less's raw-bit total order, including NaNs
 * and infinities. Only MIN/MAX and moves may carry these partial bounds.
 * Arithmetic and ARL require both finite endpoints within the proof limit.
 * Constant operands still check their independent 192-row access window. */
static const NV2AMetalProofRange readonly_unknown = { -ReadonlyProofLimit - 1,
                                                      ReadonlyProofLimit + 1, 0,
                                                      UINT32_MAX };
static BOOL readonly_known(NV2AMetalProofRange value)
{
    return value.low >= -ReadonlyProofLimit &&
           value.high <= ReadonlyProofLimit && value.low <= value.high;
}
static NV2AMetalProofRange readonly_range(int low, int high)
{
    return low < -ReadonlyProofLimit || high > ReadonlyProofLimit ?
               readonly_unknown :
               (NV2AMetalProofRange){ low, high, 0, UINT32_MAX };
}
static NV2AMetalProofRange readonly_constant(const float *constant)
{
    uint32_t bits;
    memcpy(&bits, constant, sizeof(bits));
    unsigned magnitude = bits & 0x7fffffffu, exponent = magnitude >> 23;
    if (!magnitude)
        return (NV2AMetalProofRange){ 0, 0, 0, bits };
    if (magnitude > ((127u + ReadonlyProofPower) << 23)) {
        NV2AMetalProofRange value = readonly_unknown;
        /* Preserve captured finite bits for a later exact scaling proof,
         * without assigning an out-of-domain value a finite interval. */
        if (exponent < 255) {
            value.exactBits = bits;
            value.magnitudeExponent = exponent;
        }
        return value;
    }
    if (exponent < 127)
        return bits >> 31 ? (NV2AMetalProofRange){ -1, 0, exponent, bits } :
                            (NV2AMetalProofRange){ 0, 1, exponent, bits };
    unsigned mantissa = (magnitude & 0x7fffff) | 0x800000;
    int low, high;
    if (exponent >= 150) {
        low = high = mantissa << (exponent - 150);
    } else {
        unsigned shift = 150 - exponent;
        low = mantissa >> shift;
        high = low + !!(mantissa & ((1u << shift) - 1));
    }
    NV2AMetalProofRange value =
        bits >> 31 ? readonly_range(-high, -low) : readonly_range(low, high);
    value.magnitudeExponent = exponent;
    value.exactBits = bits;
    return value;
}
static NV2AMetalProofRange
readonly_fetch_domain(const NV2AMetalFetchUniforms *u, unsigned attribute,
                      unsigned lane)
{
    const NV2AMetalFetchAttribute *a = &u->attributes[attribute];
    NV2AMetalProofRange value =
        lane == 3 ? (NV2AMetalProofRange){ 1, 1, 0, UINT32_MAX } :
                    (NV2AMetalProofRange){ 0, 0, 0, UINT32_MAX };
    if (!a->count)
        value = readonly_constant(a->inline_value + lane);
    else if (a->format == NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP)
        value = lane == 3 ? (NV2AMetalProofRange){ 1, 1, 0, UINT32_MAX } :
                            (NV2AMetalProofRange){ a->stride ? -2 : -1, 1, 0,
                                                   UINT32_MAX };
    else if (lane < a->count) {
        switch (a->format) {
        case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D:
        case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL:
            value = (NV2AMetalProofRange){ 0, 1, 0, UINT32_MAX };
            break;
        case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1:
            value = (NV2AMetalProofRange){ -1, 1, 0, UINT32_MAX };
            break;
        case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K:
            value = (NV2AMetalProofRange){ -32768, 32767, 0, UINT32_MAX };
            break;
        default:
            /* Populated Float lanes are arbitrary. */
            value = readonly_unknown;
            break;
        }
    }
    if (u->index_size && u->first_vertex) {
        /* Index addition can overflow before conversion. That path returns
         * raw inline values even for enabled normalized/missing components. */
        NV2AMetalProofRange fallback =
            readonly_constant(a->inline_value + lane);
        value.low = MIN(value.low, fallback.low);
        value.high = MAX(value.high, fallback.high);
        value.magnitudeExponent =
            MIN(value.magnitudeExponent, fallback.magnitudeExponent);
        if (value.exactBits != fallback.exactBits)
            value.exactBits = UINT32_MAX;
    }
    /* A strided out-of-range index instead yields (0,0,0,1), already enclosed.
     * The common CMP range also encloses the appended clamped Current record.
     */
    return value;
}

static NV2AMetalProofRange
readonly_float_summary(const NV2AMetalFloatLaneSummary *summary)
{
    if (summary->flags != NV2AMetalFloatLaneSummaryFinite ||
        (summary->minBits & 0x7f800000u) == 0x7f800000u ||
        (summary->maxBits & 0x7f800000u) == 0x7f800000u)
        return readonly_unknown;
    unsigned minimumExponent = (summary->minBits >> 23) & 255;
    unsigned maximumExponent = (summary->maxBits >> 23) & 255;
    if (summary->minExponent > MIN(minimumExponent, maximumExponent))
        return readonly_unknown;
    uint32_t minimumOrder = summary->minBits & 0x80000000u ?
                                ~summary->minBits :
                                summary->minBits ^ 0x80000000u;
    uint32_t maximumOrder = summary->maxBits & 0x80000000u ?
                                ~summary->maxBits :
                                summary->maxBits ^ 0x80000000u;
    if (minimumOrder > maximumOrder)
        return readonly_unknown;
    float minimum, maximum;
    memcpy(&minimum, &summary->minBits, sizeof(minimum));
    memcpy(&maximum, &summary->maxBits, sizeof(maximum));
    NV2AMetalProofRange low = readonly_constant(&minimum);
    if (summary->minBits == summary->maxBits)
        return summary->minExponent == minimumExponent ? low : readonly_unknown;
    NV2AMetalProofRange high = readonly_constant(&maximum);
    if (!readonly_known(low) || !readonly_known(high))
        return readonly_unknown;
    NV2AMetalProofRange value =
        readonly_range(MIN(low.low, high.low), MAX(low.high, high.high));
    /* Endpoints alone cannot prove a nonzero lower magnitude: interior zero
     * and subnormal values also contributed to the captured minimum. */
    value.magnitudeExponent = summary->minExponent;
    return value;
}

static NV2AMetalProofRange
readonly_fetch_domain_with_summaries(const NV2AMetalFetchUniforms *u,
                                     unsigned attribute, unsigned lane,
                                     NSData *summaries, uint64_t laneMask)
{
    const NV2AMetalFetchAttribute *a = &u->attributes[attribute];
    if (summaries.length != 64 * sizeof(NV2AMetalFloatLaneSummary) ||
        !(laneMask & (UINT64_C(1) << (attribute * 4 + lane))) ||
        a->format != NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F || !a->stride ||
        lane >= a->count || !nv2a_metal_attribute_size(a->format, a->count))
        return readonly_fetch_domain(u, attribute, lane);
    const NV2AMetalFloatLaneSummary *values = summaries.bytes;
    NV2AMetalProofRange value =
        readonly_float_summary(values + attribute * 4 + lane);
    if (u->index_size && u->first_vertex) {
        NV2AMetalProofRange fallback =
            readonly_constant(a->inline_value + lane);
        value.low = MIN(value.low, fallback.low);
        value.high = MAX(value.high, fallback.high);
        value.magnitudeExponent =
            MIN(value.magnitudeExponent, fallback.magnitudeExponent);
        if (value.exactBits != fallback.exactBits)
            value.exactBits = UINT32_MAX;
    }
    return value;
}

typedef struct NV2AMetalFetchProofDomains {
    const NV2AMetalFetchUniforms *uniforms;
    uint64_t evaluated;
    NV2AMetalProofRange values[NV2A_METAL_VP_ATTRIBUTES][4];
} NV2AMetalFetchProofDomains;

typedef struct NV2AMetalConstantProofDomains {
    const float *constants;
    NV2AMetalProofRange rows;
    unsigned evaluated;
    NV2AMetalProofRange values[4];
} NV2AMetalConstantProofDomains;

static NV2AMetalProofRange
readonly_constant_domain(const NV2AMetalConstantProofDomains *domain,
                         unsigned component)
{
    /* An exact finite value can survive a row union only when every possible
     * row has identical bits. Other unions require bounded endpoints. */
    if (domain->rows.low == domain->rows.high)
        return readonly_constant(domain->constants + 4 * domain->rows.low +
                                 component);
    NV2AMetalProofRange value = readonly_unknown;
    for (int row = domain->rows.low; row <= domain->rows.high; row++) {
        NV2AMetalProofRange one =
            readonly_constant(domain->constants + 4 * row + component);
        if (row == domain->rows.low) {
            value = one;
        } else if (!readonly_known(one) || !readonly_known(value)) {
            if (one.exactBits == UINT32_MAX || one.exactBits != value.exactBits)
                return readonly_unknown;
        } else {
            value = (NV2AMetalProofRange){
                MIN(value.low, one.low), MAX(value.high, one.high),
                MIN(value.magnitudeExponent, one.magnitudeExponent),
                value.exactBits == one.exactBits ? value.exactBits : UINT32_MAX
            };
        }
    }
    return value;
}

static NV2AMetalProofRange
readonly_source_domain(unsigned source, unsigned lane,
                       const NV2AMetalProofRange registers[13][4],
                       NV2AMetalFetchProofDomains *fetch, unsigned attribute,
                       NV2AMetalConstantProofDomains *constant)
{
    unsigned component = (source >> (6 + 2 * lane)) & 3u;
    NV2AMetalProofRange value = readonly_unknown;
    if ((source & 3u) == 1u) {
        unsigned reg = (source >> 2) & 15u;
        value = registers[reg][component];
    } else if ((source & 3u) == 2u && fetch) {
        uint64_t bit = UINT64_C(1) << (4 * attribute + component);
        NV2AMetalProofRange *cached = &fetch->values[attribute][component];
        if (!(fetch->evaluated & bit)) {
            *cached =
                readonly_fetch_domain(fetch->uniforms, attribute, component);
            fetch->evaluated |= bit;
        }
        value = *cached;
    } else if ((source & 3u) == 3u && constant->constants) {
        unsigned bit = 1u << component;
        if (!(constant->evaluated & bit)) {
            constant->values[component] =
                readonly_constant_domain(constant, component);
            constant->evaluated |= bit;
        }
        value = constant->values[component];
    } else
        return readonly_unknown;
    if (source & (1u << 14)) {
        int low = value.low;
        value.low = -value.high;
        value.high = -low;
        if (value.exactBits != UINT32_MAX)
            value.exactBits ^= 0x80000000u;
    }
    return value;
}
static BOOL readonly_scale_endpoint(int endpoint, uint32_t bits, int *low,
                                    int *high)
{
    unsigned exponent = (bits >> 23) & 255u;
    assert(exponent <
           150); /* This helper scales by a fractional coefficient. */
    int64_t mantissa = (bits & 0x7fffffu) | 0x800000u;
    int64_t product = endpoint * (bits >> 31 ? -mantissa : mantissa);
    uint64_t magnitude = product < 0 ? (uint64_t)-product : (uint64_t)product;
    unsigned shift = 150 - exponent;
    /* |endpoint| <= 2^24 and a 24-bit mantissa fit in 49 signed bits. Very
     * small nonzero coefficients round outward to [0,1] or [-1,0], without a
     * large/undefined shift or any host floating-point arithmetic. */
    uint64_t floor = shift >= 63 ? 0 : magnitude >> shift;
    uint64_t ceil =
        floor + (shift >= 63 ? magnitude != 0 :
                               !!(magnitude & ((UINT64_C(1) << shift) - 1)));
    if (ceil > ReadonlyProofLimit)
        return NO;
    *low = product < 0 ? -(int)ceil : (int)floor;
    *high = product < 0 ? -(int)floor : (int)ceil;
    return YES;
}
static BOOL readonly_product(NV2AMetalProofRange a, NV2AMetalProofRange b,
                             int *low, int *high)
{
    /* vp_multiply_rz returns +0 before examining NaN/Inf if either operand
     * has a zero exponent. This includes captured subnormal coefficients. */
    if ((a.low == 0 && a.high == 0) || (b.low == 0 && b.high == 0) ||
        (a.exactBits != UINT32_MAX && !(a.exactBits & 0x7f800000u)) ||
        (b.exactBits != UINT32_MAX && !(b.exactBits & 0x7f800000u))) {
        *low = *high = 0;
        return YES;
    }
    if (!readonly_known(a) || !readonly_known(b)) {
        /* A captured large operand can scale back into the exact integer
         * endpoint domain. Enclose the real product with integer bit math;
         * Kelvin RZ/FTZ cannot escape these representable endpoints. */
        if (a.exactBits == UINT32_MAX || b.exactBits == UINT32_MAX)
            return NO;
        unsigned ae = (a.exactBits >> 23) & 255u;
        unsigned be = (b.exactBits >> 23) & 255u;
        if (!ae || !be || ae == 255 || be == 255)
            return NO;
        uint64_t product = (uint64_t)((a.exactBits & 0x7fffffu) | 0x800000u) *
                           ((b.exactBits & 0x7fffffu) | 0x800000u);
        int shift = 300 - (int)ae - (int)be;
        if (shift <= 0)
            return NO;
        uint64_t floor = shift >= 64 ? 0 : product >> shift;
        uint64_t ceil =
            floor + (shift >= 64 || !!(product & ((UINT64_C(1) << shift) - 1)));
        if (ceil > ReadonlyProofLimit)
            return NO;
        BOOL negative = (a.exactBits ^ b.exactBits) >> 31;
        *low = negative ? -(int)ceil : (int)floor;
        *high = negative ? -(int)floor : (int)ceil;
        return YES;
    }
    BOOL fractionalA = a.exactBits != UINT32_MAX && a.low != a.high;
    BOOL fractionalB = b.exactBits != UINT32_MAX && b.low != b.high;
    if (fractionalA || fractionalB) {
        /* Use the smaller exact coefficient when both are captured. Kelvin
         * RZ multiplication cannot escape integer endpoints that enclose
         * the real product. Other values retain their full input interval. */
        BOOL exactA =
            fractionalA && (!fractionalB || (a.exactBits & 0x7fffffffu) <=
                                                (b.exactBits & 0x7fffffffu));
        NV2AMetalProofRange range = exactA ? b : a;
        uint32_t bits = exactA ? a.exactBits : b.exactBits;
        int low0, high0, low1, high1;
        if (!readonly_scale_endpoint(range.low, bits, &low0, &high0) ||
            !readonly_scale_endpoint(range.high, bits, &low1, &high1))
            return NO;
        *low = MIN(low0, low1);
        *high = MAX(high0, high1);
        return YES;
    }
    int64_t products[] = { (int64_t)a.low * b.low, (int64_t)a.low * b.high,
                           (int64_t)a.high * b.low, (int64_t)a.high * b.high };
    int64_t lower = products[0], upper = products[0];
    for (unsigned i = 1; i < 4; i++) {
        lower = MIN(lower, products[i]);
        upper = MAX(upper, products[i]);
    }
    if (lower < -ReadonlyProofLimit || upper > ReadonlyProofLimit)
        return NO;
    *low = (int)lower;
    *high = (int)upper;
    return YES;
}
/* Mirror vertex-program.metal's vp_pack_rz/vp_multiply_rz/vp_sum_rz only
 * after every required operand has proved finite exact bits. Products flush
 * zero-exponent operands to +0, overflow saturates, and sums align all terms
 * together before packing. No host floating-point arithmetic is involved. */
static uint32_t readonly_pack_rz(uint32_t sign, int exponent, uint32_t mantissa)
{
    if (exponent <= 0 || !mantissa)
        return sign;
    if (exponent >= 255)
        return sign | 0x7f7fffffu;
    return sign | ((uint32_t)exponent << 23) | (mantissa & 0x7fffffu);
}
static uint32_t readonly_multiply_rz(uint32_t a, uint32_t b)
{
    int ae = (a >> 23) & 255, be = (b >> 23) & 255;
    if (!ae || !be)
        return 0;
    uint64_t product =
        (uint64_t)((a & 0x7fffffu) | 0x800000u) * ((b & 0x7fffffu) | 0x800000u);
    BOOL high = !!(product & (UINT64_C(1) << 47));
    int exponent = ae + be - 127 + high;
    uint32_t mantissa = (uint32_t)(product >> (high ? 24 : 23));
    return readonly_pack_rz((a ^ b) & 0x80000000u, exponent, mantissa);
}
static uint32_t readonly_sum_rz(const uint32_t *values, unsigned count)
{
    int exponent = 0;
    for (unsigned i = 0; i < count; i++) {
        int e = (values[i] >> 23) & 255;
        exponent = MAX(exponent, e + 2);
    }
    int64_t sum = 0;
    for (unsigned i = 0; i < count; i++) {
        int e = (values[i] >> 23) & 255;
        uint32_t mantissa = (values[i] & 0x7fffffu) | (e ? 0x800000u : 0);
        int shift = exponent - e - 7;
        uint32_t aligned = shift >= 32 ? 0 :
                           shift >= 0  ? mantissa >> shift :
                                         mantissa << -shift;
        sum += values[i] >> 31 ? -(int64_t)aligned : (int64_t)aligned;
    }
    if (!sum)
        return 0;
    uint32_t sign = sum < 0 ? 0x80000000u : 0;
    uint32_t magnitude = (uint32_t)(sum < 0 ? -sum : sum);
    while (magnitude < 0x40000000u) {
        magnitude <<= 1;
        exponent--;
    }
    return readonly_pack_rz(sign, exponent, magnitude >> 7);
}
static BOOL readonly_exact_finite(NV2AMetalProofRange value)
{
    return value.exactBits != UINT32_MAX &&
           (value.exactBits & 0x7f800000u) != 0x7f800000u;
}
/* vp_less uses raw-bit total order, including -0 < +0 and subnormals.
 * Preserve the selected domain rather than rebuilding its integer bounds. */
static BOOL readonly_exact_selection(unsigned opcode, NV2AMetalProofRange a,
                                     NV2AMetalProofRange b,
                                     NV2AMetalProofRange *result)
{
    if ((opcode != NV2AMetalMACMin && opcode != NV2AMetalMACMax &&
         opcode != NV2AMetalMACSlt && opcode != NV2AMetalMACSge) ||
        !readonly_exact_finite(a) || !readonly_exact_finite(b))
        return NO;
    uint32_t akey =
        a.exactBits & 0x80000000u ? ~a.exactBits : a.exactBits ^ 0x80000000u;
    uint32_t bkey =
        b.exactBits & 0x80000000u ? ~b.exactBits : b.exactBits ^ 0x80000000u;
    BOOL less = akey < bkey;
    if (opcode == NV2AMetalMACMin)
        *result = less ? a : b;
    else if (opcode == NV2AMetalMACMax)
        *result = less ? b : a;
    else {
        BOOL one = opcode == NV2AMetalMACSlt ? less : !less;
        uint32_t bits = one ? 0x3f800000u : 0;
        float value;
        memcpy(&value, &bits, sizeof(value));
        *result = readonly_constant(&value);
    }
    return YES;
}
static BOOL readonly_exact_arithmetic(unsigned opcode, unsigned lane,
                                      const NV2AMetalProofRange inputs[3][4],
                                      uint32_t *result)
{
    NV2AMetalProofRange a = inputs[0][lane], b = inputs[1][lane],
                        c = inputs[2][lane];
    uint32_t values[4];
    if (opcode == NV2AMetalMACAdd) {
        if (!readonly_exact_finite(a) || !readonly_exact_finite(c))
            return NO;
        values[0] = a.exactBits;
        values[1] = c.exactBits;
        *result = readonly_sum_rz(values, 2);
    } else if (opcode == NV2AMetalMACMul || opcode == NV2AMetalMACMad ||
               (opcode == NV2AMetalMACDst && lane == 1)) {
        if (!readonly_exact_finite(a) || !readonly_exact_finite(b) ||
            (opcode == NV2AMetalMACMad && !readonly_exact_finite(c)))
            return NO;
        values[0] = readonly_multiply_rz(a.exactBits, b.exactBits);
        if (opcode == NV2AMetalMACMad) {
            values[1] = c.exactBits;
            *result = readonly_sum_rz(values, 2);
        } else
            *result = values[0];
    } else if (opcode == NV2AMetalMACDp3 || opcode == NV2AMetalMACDph ||
               opcode == NV2AMetalMACDp4) {
        unsigned count = opcode == NV2AMetalMACDp3 ? 3 : 4;
        for (unsigned i = 0; i < count; i++) {
            BOOL homogeneous = opcode == NV2AMetalMACDph && i == 3;
            if ((!homogeneous && !readonly_exact_finite(inputs[0][i])) ||
                !readonly_exact_finite(inputs[1][i]))
                return NO;
            values[i] = readonly_multiply_rz(
                homogeneous ? 0x3f800000u : inputs[0][i].exactBits,
                inputs[1][i].exactBits);
        }
        *result = readonly_sum_rz(values, count);
    } else
        return NO;
    return (*result & 0x7f800000u) != 0x7f800000u;
}
static NV2AMetalProofRange
readonly_arithmetic(unsigned opcode, unsigned lane,
                    const NV2AMetalProofRange inputs[3][4])
{
    uint32_t bits;
    if (readonly_exact_arithmetic(opcode, lane, inputs, &bits)) {
        float value;
        memcpy(&value, &bits, sizeof(value));
        return readonly_constant(&value);
    }
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
                    (NV2AMetalProofRange){ 1, 1, 0, UINT32_MAX } :
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
static unsigned readonly_reciprocal_bound(NV2AMetalProofRange scalar,
                                          unsigned opcode)
{
    if (!readonly_known(scalar)) {
        /* A captured finite value outside the integer domain is still at
         * least 2^24 in magnitude. All three Kelvin reciprocal operations
         * produce a finite result of magnitude at most one. */
        return scalar.exactBits != UINT32_MAX &&
                       scalar.magnitudeExponent >= 127 + ReadonlyProofPower &&
                       scalar.magnitudeExponent < 255 ?
                   1 :
                   0;
    }
    if (scalar.low >= 1 || scalar.high <= -1)
        return 1;
    unsigned exponent = scalar.magnitudeExponent;
    BOOL root = opcode == NV2AMetalILURsq;
    if (exponent < 127u - (root ? 2u : 1u) * ReadonlyProofPower)
        return 0;
    /* The existing Kelvin tables keep RCP/RCC within 2^(127-e), and
     * RSQ within 2^ceil((127-e)/2). Round upward to an integer power of
     * two; do not run a host approximation of the GPU's reciprocal. */
    unsigned power = exponent < 127 ? 127 - exponent : 0;
    return 1u << (root ? (power + 1) / 2 : power);
}

/* Numerical dependencies of every ARL, including unused address writes.
 * Operand apertures are checked independently by the forward proof. Masks
 * use the decoded destination convention: bit 3 is X, bit 0 is W. */
typedef struct NV2AMetalProofInstruction {
    uint8_t mac, ilu, sources[3];
} NV2AMetalProofInstruction;
typedef struct NV2AMetalProofCopy {
    uint16_t first, count;
} NV2AMetalProofCopy;
typedef struct NV2AMetalReadonlyProofInputs {
    float constants[NV2A_METAL_VP_CONSTANTS][4];
    NV2AMetalProofRange attributes[NV2A_METAL_VP_ATTRIBUTES][4];
} NV2AMetalReadonlyProofInputs;
_Static_assert(sizeof(NV2AMetalReadonlyProofInputs) == 4096,
               "Numerical proof cache layout");

static unsigned readonly_needed_write(uint8_t live[13], unsigned reg,
                                      unsigned mask)
{
    if (!mask)
        return 0;
    unsigned needed = live[reg] & mask;
    live[reg] &= ~mask;
    return needed;
}

static void readonly_plan_domains(const NV2AMetalProgramInstruction *program,
                                  NSUInteger slots,
                                  NV2AMetalProofInstruction *plan,
                                  uint8_t constants[192], uint64_t *attributes)
{
    uint8_t live[13] = { 0 };
    for (NSUInteger slot = slots; slot-- > 0;) {
        const NV2AMetalProgramInstruction *op = &program[slot];
        NV2AMetalProofInstruction step = { 0 };
        BOOL arl = op->mac == NV2AMetalMACArl;
        BOOL paired = op->mac != NV2AMetalMACNop && op->ilu != NV2AMetalILUNop;
        BOOL position = op->output_register == 256u && op->output_mask;
        /* Reverse the interpreter's writes before adding incoming operand
         * reads. R12 aliases position; paired ILU writes R1 and can suppress
         * the MAC temporary. Both units still read the old register values. */
        if (op->mac != NV2AMetalMACNop && !arl &&
            !(paired && op->temp_register == 1))
            step.mac |=
                readonly_needed_write(live, op->temp_register, op->mac_mask);
        if (op->ilu != NV2AMetalILUNop)
            step.ilu |= readonly_needed_write(
                live, paired ? 1 : op->temp_register, op->ilu_mask);
        if (position) {
            if (op->output_mux && op->ilu != NV2AMetalILUNop)
                step.ilu |= readonly_needed_write(live, 12, op->output_mask);
            else if (!op->output_mux && op->mac != NV2AMetalMACNop && !arl)
                step.mac |= readonly_needed_write(live, 12, op->output_mask);
        }
        if (arl)
            step.sources[0] = 8;
        else if (step.mac) {
            switch (op->mac) {
            case NV2AMetalMACMov:
                step.sources[0] = step.mac;
                break;
            case NV2AMetalMACAdd:
                step.sources[0] = step.sources[2] = step.mac;
                break;
            case NV2AMetalMACDp3:
                step.sources[0] = step.sources[1] = 14;
                break;
            case NV2AMetalMACDph:
                step.sources[0] = 14;
                step.sources[1] = 15;
                break;
            case NV2AMetalMACDp4:
                step.sources[0] = step.sources[1] = 15;
                break;
            case NV2AMetalMACDst:
                step.sources[0] = step.mac & 6;
                step.sources[1] = step.mac & 5;
                break;
            default:
                step.sources[0] = step.sources[1] = step.mac;
                if (op->mac == NV2AMetalMACMad)
                    step.sources[2] = step.mac;
                break;
            }
        }
        if (op->ilu == NV2AMetalILUMov)
            step.sources[2] |= step.ilu;
        else if (step.ilu && op->ilu >= NV2AMetalILURcp &&
                 op->ilu <= NV2AMetalILURsq)
            step.sources[2] |= 8;
        /* EXP/LOG's W and LIT's X/W are constants in this proof; their
         * other results are unknown regardless of the incoming values. */
        for (unsigned source = 0; source < 3; source++) {
            unsigned operand = op->source[source];
            for (unsigned lane = 0; lane < 4; lane++) {
                if (!(step.sources[source] & (8u >> lane)))
                    continue;
                unsigned component = (operand >> (6 + 2 * lane)) & 3u;
                unsigned bit = 8u >> component;
                if ((operand & 3u) == 1u)
                    live[(operand >> 2) & 15u] |= bit;
                else if ((operand & 3u) == 2u)
                    *attributes |= UINT64_C(1)
                                   << (4 * op->attribute_index + component);
                else if ((operand & 3u) == 3u) {
                    if (op->relative)
                        for (unsigned row = 0; row < 192; row++)
                            constants[row] |= bit;
                    else if (op->constant_index < 192)
                        constants[op->constant_index] |= bit;
                }
            }
        }
        plan[slot] = step;
    }
}

static unsigned
readonly_fault_free_access(const NV2AMetalProgramInstruction *program,
                           NSUInteger slots, const float *constants,
                           NV2AMetalFetchProofDomains *fetch,
                           const NV2AMetalProofInstruction *plan,
                           unsigned access, NV2AMetalConstantRows *constantRows)
{
    NV2AMetalProofRange registers[13][4] = { 0 },
                        address = { 0, 0, 0, UINT32_MAX };
    registers[12][3] = (NV2AMetalProofRange){ 1, 1, 0, UINT32_MAX };
    for (NSUInteger slot = 0; slot < slots; slot++) {
        const NV2AMetalProgramInstruction *op = &program[slot];
        const NV2AMetalProofInstruction *step = &plan[slot];
        unsigned sources = instruction_sources(op);
        /* All used operands precede output, paired ILU, temp and IDX writes,
         * even for zero destination masks. They share one constant selector
         * and the incoming IDX, so check the aperture once on the first use. */
        NV2AMetalConstantProofDomains constant;
        constant.constants = constants;
        constant.evaluated = 0;
        for (unsigned source = 0; source < 3; source++) {
            if ((sources & (1u << source)) && (op->source[source] & 3u) == 3u) {
                NV2AMetalProofRange offsets =
                    op->relative ? address :
                                   (NV2AMetalProofRange){ 0, 0, 0, UINT32_MAX };
                int low = (int)op->constant_index + offsets.low;
                int high = (int)op->constant_index + offsets.high;
                if (low < 0 || high >= NV2A_METAL_VP_CONSTANTS)
                    return 0;
                if (low < 96 && (op->relative || (low != 58 && low != 59)))
                    access &= ~1u;
                if (!access)
                    return 0;
                constant.rows =
                    (NV2AMetalProofRange){ low, high, 0, UINT32_MAX };
                if (constantRows)
                    constantRows[slot] =
                        (NV2AMetalConstantRows){ (uint16_t)low,
                                                 (uint16_t)high };
                break;
            }
        }
        BOOL arl = op->mac == NV2AMetalMACArl;
        BOOL paired = op->mac != NV2AMetalMACNop && op->ilu != NV2AMetalILUNop;
        BOOL position = op->output_register == 256u && op->output_mask;
        BOOL output_mac =
            position && !op->output_mux && op->mac != NV2AMetalMACNop && !arl;
        BOOL output_ilu =
            position && op->output_mux && op->ilu != NV2AMetalILUNop;
        BOOL temp_mac = op->mac != NV2AMetalMACNop && !arl && op->mac_mask &&
                        !(paired && op->temp_register == 1);
        BOOL temp_ilu = op->ilu != NV2AMetalILUNop && op->ilu_mask;
        /* The other outputs cannot feed an address. Their operand aperture
         * still matters even though their numerical ranges do not. */
        if (!arl && !step->mac && !step->ilu)
            continue;
        NV2AMetalProofRange inputs[3][4], mac[4], ilu[4];
        for (unsigned lane = 0; lane < 4; lane++) {
            mac[lane] = ilu[lane] = readonly_unknown;
            for (unsigned source = 0; source < 3; source++)
                inputs[source][lane] = readonly_unknown;
        }
        for (unsigned source = 0; source < 3; source++) {
            if (!step->sources[source])
                continue;
            for (unsigned lane = 0; lane < 4; lane++)
                if (step->sources[source] & (8u >> lane))
                    inputs[source][lane] = readonly_source_domain(
                        op->source[source], lane, registers, fetch,
                        op->attribute_index, &constant);
        }
        if (arl && !readonly_known(inputs[0][0]))
            return 0; /* Unknown ARL may fault even without a later read. */
        BOOL dot = op->mac >= NV2AMetalMACDp3 && op->mac <= NV2AMetalMACDp4;
        NV2AMetalProofRange dotValue =
            dot && step->mac ? readonly_arithmetic(op->mac, 0, inputs) :
                               readonly_unknown;
        for (unsigned lane = 0; lane < 4; lane++) {
            if (!(step->mac & (8u >> lane)))
                continue;
            if (readonly_exact_selection(op->mac, inputs[0][lane],
                                         inputs[1][lane], &mac[lane]))
                continue;
            if (op->mac == NV2AMetalMACMov)
                mac[lane] = inputs[0][lane];
            else if (op->mac == NV2AMetalMACSlt || op->mac == NV2AMetalMACSge) {
                mac[lane] = (NV2AMetalProofRange){ 0, 1, 0, UINT32_MAX };
                NV2AMetalProofRange a = inputs[0][lane], b = inputs[1][lane];
                if (readonly_known(a) && readonly_known(b)) {
                    if (a.high < b.low) {
                        int value = op->mac == NV2AMetalMACSlt;
                        mac[lane] = (NV2AMetalProofRange){ value, value, 0,
                                                           UINT32_MAX };
                    } else if (a.low >= b.high && (a.low != 0 || b.high != 0)) {
                        /* vp_less orders -0 below +0. Integer intervals do
                         * not retain that distinction, so zero ties stay
                         * unproven even when both endpoints are known. */
                        int value = op->mac == NV2AMetalMACSge;
                        mac[lane] = (NV2AMetalProofRange){ value, value, 0,
                                                           UINT32_MAX };
                    }
                }
            } else if (op->mac == NV2AMetalMACMin || op->mac == NV2AMetalMACMax)
                mac[lane] =
                    op->mac == NV2AMetalMACMin ?
                        (NV2AMetalProofRange){
                            MIN(inputs[0][lane].low, inputs[1][lane].low),
                            MIN(inputs[0][lane].high, inputs[1][lane].high), 0,
                            UINT32_MAX
                        } :
                        (NV2AMetalProofRange){
                            MAX(inputs[0][lane].low, inputs[1][lane].low),
                            MAX(inputs[0][lane].high, inputs[1][lane].high), 0,
                            UINT32_MAX
                        };
            else
                mac[lane] =
                    dot ? dotValue : readonly_arithmetic(op->mac, lane, inputs);
        }
        if (op->ilu == NV2AMetalILUMov)
            for (unsigned lane = 0; lane < 4; lane++)
                if (step->ilu & (8u >> lane))
                    ilu[lane] = inputs[2][lane];
        if (op->mac == NV2AMetalMACDst) {
            mac[0] = (NV2AMetalProofRange){ 1, 1, 0, UINT32_MAX };
            mac[2] = inputs[0][2];
            mac[3] = inputs[1][3];
        }
        NV2AMetalProofRange scalar = inputs[2][0];
        unsigned bound =
            op->ilu >= NV2AMetalILURcp && op->ilu <= NV2AMetalILURsq ?
                readonly_reciprocal_bound(scalar, op->ilu) :
                0;
        if (bound) {
            BOOL root = op->ilu == NV2AMetalILURsq;
            int low = root || scalar.low >= 0 ? 0 : -(int)bound;
            int high = !root && scalar.high <= 0 ? 0 : (int)bound;
            for (unsigned lane = 0; lane < 4; lane++)
                ilu[lane] = (NV2AMetalProofRange){ low, high, 0, UINT32_MAX };
        }
        if (op->ilu >= NV2AMetalILUExp)
            ilu[3] = (NV2AMetalProofRange){ 1, 1, 0, UINT32_MAX };
        if (op->ilu == NV2AMetalILULit)
            ilu[0] = (NV2AMetalProofRange){ 1, 1, 0, UINT32_MAX };
        if (output_ilu)
            readonly_write_domains(registers[12], ilu, op->output_mask);
        else if (output_mac)
            readonly_write_domains(registers[12], mac, op->output_mask);
        if (temp_ilu)
            readonly_write_domains(registers[paired ? 1 : op->temp_register],
                                   ilu, op->ilu_mask);
        if (arl)
            address = inputs[0][0];
        else if (temp_mac)
            readonly_write_domains(registers[op->temp_register], mac,
                                   op->mac_mask);
    }
    return access;
}
@interface NV2AMetalValidatedProgram ()
@property(nonatomic, readonly) NSData *writtenConstantLanes;
- (BOOL)canRefineConstants:(const float *)constants
          initialConstants:(NSData *)initial
     excludingWrittenLanes:(const uint8_t *)written;
/* Encoding has already rejected the constant-only proof. This refinement
 * independently validates the captured attribute domains and write aliases. */
- (BOOL)refineIndependentConstantWrites:(unsigned)access
                              constants:(const float *)constants
                         sourceUniforms:
                             (const NV2AMetalFetchUniforms *)sourceUniforms;
- (BOOL)refineIndependentConstantWrites:(unsigned)access
                              constants:(const float *)constants
                         sourceUniforms:
                             (const NV2AMetalFetchUniforms *)sourceUniforms
                         floatSummaries:(NSData *)summaries
                               laneMask:(uint64_t)laneMask;
- (BOOL)boundWriterProofConstants:(const float *)constants
                     fetchDomains:(const void *)domains
                    matchSnapshot:(NSData *)snapshot;
- (NSData *)boundWriterProofKeyWithBytes:(const void *)bytes
                                  length:(NSUInteger)length;
- (BOOL)evaluateBoundWriterAccess:(unsigned)access
                        constants:(const float *)constants
                     fetchDomains:(void *)domains;
@end
@implementation NV2AMetalValidatedProgram {
    unsigned _faultFreeReadOnlyAccess;
    unsigned _independentWriteAccess, _writerAccess;
    NSData *_writtenConstantLanes, *_writerProofInputs;
    unsigned _writerProofKnown, _writerProofAllowed;
    NSData *_boundWriterProofInputs;
    unsigned _boundWriterProofKnown, _boundWriterProofAllowed;
    NSData *_constantProofInputs, *_fetchProofInputs;
    unsigned _proofKnown[2], _proofAllowed[2];
    NSData *_proofPlan, *_proofConstantCopies;
    uint64_t _proofAttributeLanes;
}
- (NSData *)writtenConstantLanes
{
    return _writtenConstantLanes;
}
- (uint64_t)readonlyProofAttributeLanes64
{
    return _proofAttributeLanes;
}
- (BOOL)canRefineConstants:(const float *)constants
          initialConstants:(NSData *)initial
     excludingWrittenLanes:(const uint8_t *)written
{
    const NSUInteger components = NV2A_METAL_VP_CONSTANTS * 4;
    if (!constants || !written ||
        initial.length != components * sizeof(float) || !_proofPlan ||
        !_proofConstantCopies ||
        _proofConstantCopies.length % sizeof(NV2AMetalProofCopy))
        return NO;
    const NV2AMetalProofCopy *copies = _proofConstantCopies.bytes;
    NSUInteger count = _proofConstantCopies.length / sizeof(*copies);
    const float *baseline = initial.bytes;
    for (NSUInteger i = 0; i < count; i++) {
        NV2AMetalProofCopy span = copies[i];
        if (span.first > components || span.count > components - span.first)
            return NO;
        for (NSUInteger component = span.first;
             component < (NSUInteger)span.first + span.count; component++)
            if (written[component / 4] & (8u >> (component % 4)))
                return NO;
        if (memcmp(constants + span.first, baseline + span.first,
                   span.count * sizeof(float)))
            return NO;
    }
    return YES;
}
- (BOOL)hasIndependentConstantWrites:(unsigned)access
{
    return access <= 1 && (_independentWriteAccess & (1u << access));
}
- (BOOL)proofConstants:(const float *)constants matchSnapshot:(NSData *)snapshot
{
    if (!constants ||
        snapshot.length <
            sizeof(((NV2AMetalReadonlyProofInputs *)0)->constants))
        return NO;
    /* The immutable dependency plan wrote every other snapshot lane as zero.
     * Compare the same raw source bits without rebuilding those zero lanes. */
    const uint8_t *cached = snapshot.bytes;
    const NV2AMetalProofCopy *copies = _proofConstantCopies.bytes;
    NSUInteger count = _proofConstantCopies.length / sizeof(*copies);
    for (NSUInteger i = 0; i < count; i++) {
        NV2AMetalProofCopy span = copies[i];
        if (memcmp(cached + span.first * sizeof(float), constants + span.first,
                   span.count * sizeof(float)))
            return NO;
    }
    return YES;
}
- (BOOL)hasIndependentConstantWrites:(unsigned)access
                           constants:(const float *)constants
{
    if ([self hasIndependentConstantWrites:access])
        return YES;
    if (access > 1 || !constants || !(_writerAccess & (1u << access)) ||
        !_proofPlan)
        return NO;
    unsigned bit = 1u << access;
    @synchronized(self) {
        if (_writerProofInputs.length ==
                NV2A_METAL_VP_CONSTANTS * 4 * sizeof(float) &&
            (_writerProofKnown & bit) &&
            [self proofConstants:constants matchSnapshot:_writerProofInputs])
            return (_writerProofAllowed & bit) != 0;
        float inputs[NV2A_METAL_VP_CONSTANTS][4] = { 0 };
        const NV2AMetalProofCopy *copies = _proofConstantCopies.bytes;
        NSUInteger copyCount = _proofConstantCopies.length / sizeof(*copies);
        for (NSUInteger i = 0; i < copyCount; i++) {
            NV2AMetalProofCopy span = copies[i];
            memcpy((uint8_t *)inputs + span.first * sizeof(float),
                   constants + span.first, span.count * sizeof(float));
        }
        if (_writerProofInputs.length != sizeof(inputs) ||
            memcmp(_writerProofInputs.bytes, inputs, sizeof(inputs))) {
            _writerProofInputs = [NSData dataWithBytes:inputs
                                                length:sizeof(inputs)];
            _writerProofKnown = _writerProofAllowed = 0;
        }
        if (!(_writerProofKnown & bit)) {
            NV2AMetalConstantRows rows[NV2A_METAL_VP_SLOTS];
            BOOL allowed = readonly_fault_free_access(
                               _instructions.bytes, _slots, inputs[0], NULL,
                               _proofPlan.bytes, bit, rows) != 0;
            if (allowed) {
                uint8_t readLanes[192] = { 0 };
                independent_constant_reads(_instructions.bytes, _slots, rows,
                                           readLanes);
                const uint8_t *written = _writtenConstantLanes.bytes;
                for (unsigned row = 0; row < 192; row++)
                    if (readLanes[row] & written[row])
                        allowed = NO;
            }
            _writerProofKnown |= bit;
            if (allowed)
                _writerProofAllowed |= bit;
        }
        return (_writerProofAllowed & bit) != 0;
    }
}
- (BOOL)hasIndependentConstantWrites:(unsigned)access
                           constants:(const float *)constants
                      sourceUniforms:
                          (const NV2AMetalFetchUniforms *)sourceUniforms
{
    if ([self hasIndependentConstantWrites:access constants:constants])
        return YES;
    return [self refineIndependentConstantWrites:access
                                       constants:constants
                                  sourceUniforms:sourceUniforms];
}
- (BOOL)refineIndependentConstantWrites:(unsigned)access
                              constants:(const float *)constants
                         sourceUniforms:
                             (const NV2AMetalFetchUniforms *)sourceUniforms
{
    return [self refineIndependentConstantWrites:access
                                       constants:constants
                                  sourceUniforms:sourceUniforms
                                  floatSummaries:nil
                                        laneMask:0];
}
- (BOOL)hasIndependentConstantWrites:(unsigned)access
                           constants:(const float *)constants
                      sourceUniforms:
                          (const NV2AMetalFetchUniforms *)sourceUniforms
                      floatSummaries:(NSData *)summaries
                            laneMask:(uint64_t)laneMask
{
    if ([self hasIndependentConstantWrites:access constants:constants])
        return YES;
    return [self refineIndependentConstantWrites:access
                                       constants:constants
                                  sourceUniforms:sourceUniforms
                                  floatSummaries:summaries
                                        laneMask:laneMask];
}
- (BOOL)refineIndependentConstantWrites:(unsigned)access
                              constants:(const float *)constants
                         sourceUniforms:
                             (const NV2AMetalFetchUniforms *)sourceUniforms
                         floatSummaries:(NSData *)summaries
                               laneMask:(uint64_t)laneMask
{
    if (access > 1 || !constants || !sourceUniforms ||
        !(_writerAccess & (1u << access)) || !_proofPlan)
        return NO;
    /* Encoding still proves GPU-context provenance and the exact Fetch
     * binding before every call. Cache only this pure numerical refinement;
     * neither proof ownership nor a queue resource participates in its key. */
    NV2AMetalFetchProofDomains fetch;
    fetch.uniforms = sourceUniforms;
    fetch.evaluated = 0;
    uint64_t remaining = _proofAttributeLanes;
    while (remaining) {
        unsigned component = __builtin_ctzll(remaining);
        remaining &= remaining - 1;
        fetch.values[component / 4][component % 4] =
            readonly_fetch_domain_with_summaries(sourceUniforms, component / 4,
                                                 component % 4, summaries,
                                                 laneMask);
        fetch.evaluated |= UINT64_C(1) << component;
    }
    unsigned bit = 1u << access;
    @synchronized(self) {
        if ((_boundWriterProofKnown & bit) &&
            [self boundWriterProofConstants:constants
                               fetchDomains:&fetch
                              matchSnapshot:_boundWriterProofInputs])
            return (_boundWriterProofAllowed & bit) != 0;
        NV2AMetalReadonlyProofInputs inputs = { 0 };
        /* One cold snapshot supplies both the original numerical analysis
         * and the retained key. Unused constants are owned but ignored by
         * sparse matching, including when the other access bit is unknown. */
        memcpy(inputs.constants, constants, sizeof(inputs.constants));
        remaining = _proofAttributeLanes;
        while (remaining) {
            unsigned component = __builtin_ctzll(remaining);
            remaining &= remaining - 1;
            inputs.attributes[component / 4][component % 4] =
                fetch.values[component / 4][component % 4];
        }
        BOOL allowed = [self evaluateBoundWriterAccess:access
                                             constants:inputs.constants[0]
                                          fetchDomains:&fetch];
        /* Equality here only preserves the existing key/other access bit.
         * A lookup miss ALWAYS evaluates above, including a forced miss. */
        BOOL same =
            _boundWriterProofInputs.length == sizeof(inputs) &&
            [self proofConstants:inputs.constants[0]
                   matchSnapshot:_boundWriterProofInputs] &&
            !memcmp((const uint8_t *)_boundWriterProofInputs.bytes +
                        offsetof(NV2AMetalReadonlyProofInputs, attributes),
                    inputs.attributes, sizeof(inputs.attributes));
        if (!same) {
            NSData *snapshot =
                [[self boundWriterProofKeyWithBytes:&inputs
                                             length:sizeof(inputs)] copy];
            _boundWriterProofInputs =
                snapshot.length == sizeof(inputs) ? snapshot : nil;
            _boundWriterProofKnown = _boundWriterProofAllowed = 0;
        }
        if (_boundWriterProofInputs) {
            _boundWriterProofKnown |= bit;
            if (allowed)
                _boundWriterProofAllowed |= bit;
            else
                _boundWriterProofAllowed &= ~bit;
        }
        return allowed;
    }
}
- (BOOL)boundWriterProofConstants:(const float *)constants
                     fetchDomains:(const void *)domains
                    matchSnapshot:(NSData *)snapshot
{
    if (snapshot.length != sizeof(NV2AMetalReadonlyProofInputs) ||
        ![self proofConstants:constants matchSnapshot:snapshot])
        return NO;
    const NV2AMetalFetchProofDomains *fetch = domains;
    const uint8_t *bytes = snapshot.bytes;
    uint64_t remaining = _proofAttributeLanes;
    while (remaining) {
        unsigned component = __builtin_ctzll(remaining);
        remaining &= remaining - 1;
        NSUInteger offset = offsetof(NV2AMetalReadonlyProofInputs, attributes) +
                            component * sizeof(NV2AMetalProofRange);
        if (memcmp(bytes + offset, &fetch->values[component / 4][component % 4],
                   sizeof(NV2AMetalProofRange)))
            return NO;
    }
    return YES;
}
- (NSData *)boundWriterProofKeyWithBytes:(const void *)bytes
                                  length:(NSUInteger)length
{
    return [NSData dataWithBytes:bytes length:length];
}
- (BOOL)evaluateBoundWriterAccess:(unsigned)access
                        constants:(const float *)constants
                     fetchDomains:(void *)domains
{
    NV2AMetalFetchProofDomains *fetch = domains;
    NV2AMetalConstantRows rows[NV2A_METAL_VP_SLOTS];
    if (!readonly_fault_free_access(_instructions.bytes, _slots, constants,
                                    fetch, _proofPlan.bytes, 1u << access,
                                    rows))
        return NO;
    uint8_t readLanes[192] = { 0 };
    independent_constant_reads(_instructions.bytes, _slots, rows, readLanes);
    const uint8_t *written = _writtenConstantLanes.bytes;
    for (unsigned row = 0; row < 192; row++)
        if (readLanes[row] & written[row])
            return NO;
    return YES;
}
- (BOOL)hasFaultFreeReadOnlyAccess:(unsigned)access
{
    return access <= 1 && (_faultFreeReadOnlyAccess & (1u << access));
}
- (BOOL)hasFaultFreeReadOnlyAccess:(unsigned)access
                         constants:(const float *)constants
{
    return [self hasFaultFreeReadOnlyAccess:access
                                  constants:constants
                             sourceUniforms:NULL];
}
- (BOOL)hasFaultFreeReadOnlyAccess:(unsigned)access
                         constants:(const float *)constants
                    sourceUniforms:
                        (const NV2AMetalFetchUniforms *)sourceUniforms
{
    return [self hasFaultFreeReadOnlyAccess:access
                                  constants:constants
                             sourceUniforms:sourceUniforms
                             floatSummaries:nil
                                   laneMask:0];
}
- (BOOL)hasFaultFreeReadOnlyAccess:(unsigned)access
                         constants:(const float *)constants
                    sourceUniforms:
                        (const NV2AMetalFetchUniforms *)sourceUniforms
                    floatSummaries:(NSData *)summaries
                          laneMask:(uint64_t)laneMask
{
    if ([self hasFaultFreeReadOnlyAccess:access])
        return YES;
    if (access > 1 || !constants)
        return NO;
    NV2AMetalFetchProofDomains fetch;
    fetch.uniforms = sourceUniforms;
    fetch.evaluated = 0;
    if (sourceUniforms) {
        uint64_t remaining = _proofAttributeLanes;
        while (remaining) {
            unsigned component = __builtin_ctzll(remaining);
            unsigned attribute = component / 4, lane = component % 4;
            remaining &= remaining - 1;
            NV2AMetalProofRange value = readonly_fetch_domain_with_summaries(
                sourceUniforms, attribute, lane, summaries, laneMask);
            fetch.values[attribute][lane] = value;
            fetch.evaluated |= UINT64_C(1) << component;
        }
    }
    /* Key only numerical address dependencies. Other operand apertures depend
     * on the immutable instructions and these same incoming address values;
     * color-only values, DMA addresses and unused lanes cannot change them. */
    unsigned scope = sourceUniforms ? 1 : 0, bit = 1u << access;
    @synchronized(self) {
        NSData *cached = scope ? _fetchProofInputs : _constantProofInputs;
        BOOL matches = cached.length == sizeof(NV2AMetalReadonlyProofInputs) &&
                       (_proofKnown[scope] & bit) &&
                       [self proofConstants:constants matchSnapshot:cached];
        if (matches && sourceUniforms) {
            const uint8_t *bytes = cached.bytes;
            uint64_t remaining = _proofAttributeLanes;
            while (remaining) {
                unsigned component = __builtin_ctzll(remaining);
                unsigned attribute = component / 4, lane = component % 4;
                remaining &= remaining - 1;
                NSUInteger offset =
                    offsetof(NV2AMetalReadonlyProofInputs, attributes) +
                    component * sizeof(NV2AMetalProofRange);
                if (memcmp(bytes + offset, &fetch.values[attribute][lane],
                           sizeof(NV2AMetalProofRange))) {
                    matches = NO;
                    break;
                }
            }
        }
        if (matches)
            return (_proofAllowed[scope] & bit) != 0;
        NV2AMetalReadonlyProofInputs inputs = { 0 };
        const NV2AMetalProofCopy *copies = _proofConstantCopies.bytes;
        NSUInteger copyCount = _proofConstantCopies.length / sizeof(*copies);
        for (NSUInteger i = 0; i < copyCount; i++) {
            NV2AMetalProofCopy span = copies[i];
            memcpy((uint8_t *)inputs.constants + span.first * sizeof(float),
                   constants + span.first, span.count * sizeof(float));
        }
        if (sourceUniforms) {
            uint64_t remaining = _proofAttributeLanes;
            while (remaining) {
                unsigned component = __builtin_ctzll(remaining);
                unsigned attribute = component / 4, lane = component % 4;
                remaining &= remaining - 1;
                inputs.attributes[attribute][lane] =
                    fetch.values[attribute][lane];
            }
        }
        if (cached.length != sizeof(inputs) ||
            memcmp(cached.bytes, &inputs, sizeof(inputs))) {
            cached = [NSData dataWithBytes:&inputs length:sizeof(inputs)];
            if (scope)
                _fetchProofInputs = cached;
            else
                _constantProofInputs = cached;
            _proofKnown[scope] = _proofAllowed[scope] = 0;
        }
        if (!(_proofKnown[scope] & bit)) {
            BOOL allowed = readonly_fault_free_access(
                               _instructions.bytes, _slots, inputs.constants[0],
                               sourceUniforms ? &fetch : NULL, _proofPlan.bytes,
                               bit, NULL) != 0;
            _proofKnown[scope] |= bit;
            if (allowed)
                _proofAllowed[scope] |= bit;
        }
        return (_proofAllowed[scope] & bit) != 0;
    }
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
    NV2AMetalProofInstruction proof[NV2A_METAL_VP_SLOTS];
    uint8_t constantLanes[NV2A_METAL_VP_CONSTANTS] = { 0 };
    readonly_plan_domains(decoded, _slots, proof, constantLanes,
                          &_proofAttributeLanes);
    NV2AMetalConstantRows constantRows[NV2A_METAL_VP_SLOTS];
    _faultFreeReadOnlyAccess = readonly_fault_free_access(
        decoded, _slots, NULL, NULL, proof, 3u, constantRows);
    uint8_t readLanes[192] = { 0 }, writtenLanes[192] = { 0 };
    unsigned writeAccess = 3u;
    for (NSUInteger i = 0; i < _slots; i++) {
        const NV2AMetalProgramInstruction *op = &decoded[i];
        unsigned sources = instruction_sources(op);
        for (unsigned source = 0; source < 3; source++) {
            if ((sources & (1u << source)) && (op->source[source] & 3u) == 2u) {
                _readAttributes |= 1u << op->attribute_index;
            }
        }
        BOOL selected = op->output_mux ? op->ilu != NV2AMetalILUNop :
                                         (op->mac != NV2AMetalMACNop &&
                                          op->mac != NV2AMetalMACArl);
        if (selected && op->output_mask && !(op->output_register & 256u)) {
            _mayWriteConstants = YES;
            unsigned row = op->output_register;
            writtenLanes[row] |= op->output_mask;
            if (row < 96 && row != 58 && row != 59)
                writeAccess &= ~1u;
        }
    }
    /* This construction-time result is independent of captured values.
     * Include every possible relative row and every ARL dependency to
     * exclude intra-/inter-vertex feedback. */
    if (_mayWriteConstants && _faultFreeReadOnlyAccess) {
        independent_constant_reads(decoded, _slots, constantRows, readLanes);
        _independentWriteAccess = _faultFreeReadOnlyAccess & writeAccess;
        for (unsigned row = 0; row < 192; row++)
            if (readLanes[row] & writtenLanes[row])
                _independentWriteAccess = 0;
    }
    _writerAccess = _mayWriteConstants ? writeAccess : 0;
    /* Every validated program contributes to chained provenance, including
     * static writers and the explicit zero mask of a program without stores.
     * Possible writes remain conservative even if execution later faults. */
    _writtenConstantLanes = [NSData dataWithBytes:writtenLanes
                                           length:sizeof(writtenLanes)];
    if (!_writtenConstantLanes) {
        program_error(error, @"Cannot retain writer component dependencies");
        return nil;
    }
    /* Retain address dependencies also when captured values can narrow a
     * statically fault-free writer's overlapping relative ranges. */
    if (_faultFreeReadOnlyAccess != 3u ||
        (_writerAccess & ~_independentWriteAccess)) {
        NV2AMetalProofCopy copies[NV2A_METAL_VP_CONSTANTS * 4];
        unsigned count = 0;
        for (unsigned component = 0; component < NV2A_METAL_VP_CONSTANTS * 4;
             component++) {
            if (!(constantLanes[component / 4] & (8u >> (component % 4))))
                continue;
            if (count &&
                copies[count - 1].first + copies[count - 1].count == component)
                copies[count - 1].count++;
            else
                copies[count++] =
                    (NV2AMetalProofCopy){ (uint16_t)component, 1 };
        }
        _proofConstantCopies = [NSData dataWithBytes:copies
                                              length:count * sizeof(copies[0])];
        _proofPlan = [NSData dataWithBytes:proof
                                    length:_slots * sizeof(proof[0])];
        if (!_proofPlan || !_proofConstantCopies) {
            program_error(error,
                          @"Cannot retain vertex address-proof dependencies");
            return nil;
        }
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

NSData *nv2a_metal_zero_constant_writes(void)
{
    static NSData *written;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      static const uint32_t zero[NV2A_METAL_VP_CONSTANTS] = { 0 };
      written = [NSData dataWithBytes:zero length:sizeof(zero)];
    });
    return written;
}

@interface NV2AMetalWritableResult ()
- (instancetype)initReadOnlyWithConstants:(NSData *)constants
                                registers:(id<MTLBuffer>)registers
                                 vertices:(id<MTLBuffer>)vertices
                                    count:(NSUInteger)count;
- (instancetype)initWithContext:(const NV2AMetalWritableContext *)context
                      registers:(id<MTLBuffer>)registers
                       vertices:(id<MTLBuffer>)vertices
                          count:(NSUInteger)count;
@end
@implementation NV2AMetalWritableResult
- (instancetype)initReadOnlyWithConstants:(NSData *)constants
                                registers:(id<MTLBuffer>)registers
                                 vertices:(id<MTLBuffer>)vertices
                                    count:(NSUInteger)count
{
    self = [super init];
    if (self) {
        _constants = [constants copy];
        _written = nv2a_metal_zero_constant_writes();
        _registers = registers;
        _vertices = vertices;
        _vertexCount = count;
    }
    return self;
}
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
@interface NV2AMetalWritableProgram ()
- (NSData *)snapshotConstants:(const float *)constants;
@end
@interface NV2AMetalWritableEncoding ()
@property(nonatomic, readonly, nullable) id<MTLBuffer> serialContext;
- (BOOL)belongsToRecording:(NV2AMetalCommands *)commands;
- (BOOL)canRefineConstantsForProgram:(NV2AMetalValidatedProgram *)program
                           constants:(const float *)constants
                            commands:(NV2AMetalCommands *)commands;
- (instancetype)initRaw:(id<MTLBuffer>)raw
               vertices:(id<MTLBuffer>)vertices
                context:(id<MTLBuffer>)context
             parameters:(const NV2AMetalWritableParameters *)parameters
                compact:(BOOL)compact
      faultFreeReadOnly:(BOOL)faultFreeReadOnly
       validatedProgram:(NV2AMetalValidatedProgram *)validated
               previous:(NV2AMetalWritableEncoding *)previous
               commands:(NV2AMetalCommands *)commands;
- (instancetype)initRaw:(id<MTLBuffer>)raw
                 vertices:(id<MTLBuffer>)vertices
                  context:(id<MTLBuffer>)context
               parameters:(const NV2AMetalWritableParameters *)parameters
    constantSnapshotOwner:(nullable NV2AMetalWritableProgram *)snapshotOwner
                  compact:(BOOL)compact
        faultFreeReadOnly:(BOOL)faultFreeReadOnly
         validatedProgram:(NV2AMetalValidatedProgram *)validated
                 previous:(NV2AMetalWritableEncoding *)previous
                 commands:(NV2AMetalCommands *)commands;
@end
@implementation NV2AMetalWritableEncoding {
    id<MTLBuffer> _raw, _vertices, _context;
    NSData *_constants;
    NSUInteger _count;
    BOOL _writeEnable, _compact, _faultFreeReadOnly;
    BOOL _writerProvenanceKnown;
    uint8_t _cumulativeWrittenLanes[NV2A_METAL_VP_CONSTANTS];
    __weak NV2AMetalCommands *_owner;
    uint64_t _recordingSerial;
}
- (instancetype)initRaw:(id<MTLBuffer>)raw
               vertices:(id<MTLBuffer>)vertices
                context:(id<MTLBuffer>)context
             parameters:(const NV2AMetalWritableParameters *)parameters
                compact:(BOOL)compact
      faultFreeReadOnly:(BOOL)faultFreeReadOnly
       validatedProgram:(NV2AMetalValidatedProgram *)validated
               previous:(NV2AMetalWritableEncoding *)previous
               commands:(NV2AMetalCommands *)commands
{
    return [self initRaw:raw
                     vertices:vertices
                      context:context
                   parameters:parameters
        constantSnapshotOwner:nil
                      compact:compact
            faultFreeReadOnly:faultFreeReadOnly
             validatedProgram:validated
                     previous:previous
                     commands:commands];
}
- (instancetype)initRaw:(id<MTLBuffer>)raw
                 vertices:(id<MTLBuffer>)vertices
                  context:(id<MTLBuffer>)context
               parameters:(const NV2AMetalWritableParameters *)parameters
    constantSnapshotOwner:(NV2AMetalWritableProgram *)snapshotOwner
                  compact:(BOOL)compact
        faultFreeReadOnly:(BOOL)faultFreeReadOnly
         validatedProgram:(NV2AMetalValidatedProgram *)validated
                 previous:(NV2AMetalWritableEncoding *)previous
                 commands:(NV2AMetalCommands *)commands
{
    self = [super init];
    if (self) {
        _raw = raw;
        _vertices = vertices;
        _context = context;
        _count = parameters->common.vertex_count;
        _writeEnable = parameters->write_enable;
        /* Writer resolution reads the GPU context. Retain its original host
         * baseline once across the chain instead of copying ignored child
         * constants or retaining the predecessor encoding. Readonly may share
         * an owning, byte-identical snapshot; never borrow parameter storage.
         */
        _constants =
            _writeEnable && previous ?
                previous->_constants :
            !_writeEnable && snapshotOwner ?
                [[snapshotOwner
                    snapshotConstants:&parameters->common.constants[0][0]]
                    copy] :
                [NSData dataWithBytes:parameters->common.constants
                               length:sizeof(parameters->common.constants)];
        NSData *written = validated.writtenConstantLanes;
        _writerProvenanceKnown =
            _writeEnable &&
            [validated isMemberOfClass:NV2AMetalValidatedProgram.class] &&
            written.length == sizeof(_cumulativeWrittenLanes) &&
            _constants.length == sizeof(parameters->common.constants) &&
            (!previous || (previous->_writerProvenanceKnown &&
                           [previous belongsToRecording:commands]));
        if (_writerProvenanceKnown) {
            const uint8_t *lanes = written.bytes;
            for (NSUInteger row = 0; row < NV2A_METAL_VP_CONSTANTS; row++)
                _cumulativeWrittenLanes[row] =
                    lanes[row] |
                    (previous ? previous->_cumulativeWrittenLanes[row] : 0);
        } else {
            memset(_cumulativeWrittenLanes, 15,
                   sizeof(_cumulativeWrittenLanes));
        }
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
- (BOOL)canRefineConstantsForProgram:(NV2AMetalValidatedProgram *)program
                           constants:(const float *)constants
                            commands:(NV2AMetalCommands *)commands
{
    return _writeEnable && _writerProvenanceKnown &&
           [self belongsToRecording:commands] &&
           [program isMemberOfClass:NV2AMetalValidatedProgram.class] &&
           [program canRefineConstants:constants
                      initialConstants:_constants
                 excludingWrittenLanes:_cumulativeWrittenLanes];
}
- (NV2AMetalWritableResult *)pendingReadOnlyResultForCommands:
                                 (NV2AMetalCommands *)commands
                                                        error:(NSError **)error
{
    if (![self canUsePendingReadOnlyResultForCommands:commands]) {
        program_error(error,
                      @"Pending readonly output needs a proven live recording");
        return nil;
    }
    return [[NV2AMetalWritableResult alloc] initReadOnlyWithConstants:_constants
                                                            registers:nil
                                                             vertices:_vertices
                                                                count:_count];
}
- (BOOL)canUsePendingReadOnlyResultForCommands:(NV2AMetalCommands *)commands
{
    return _faultFreeReadOnly && [self belongsToRecording:commands];
}
- (NV2AMetalWritableResult *)resolveWithError:(NSError **)error
{
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
        return [[NV2AMetalWritableResult alloc]
            initReadOnlyWithConstants:_constants
                            registers:_compact ? nil : _raw
                             vertices:_vertices
                                count:_count];
    }
    const NV2AMetalWritableContext *snapshot = _context.contents;
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

/* Stored identities own every declared byte, including trailing slots after
 * END. The encoding-thread lookup identity borrows only during an LRU read. */
static NSUInteger program_key_hash(const void *bytes, NSUInteger length)
{
    const uint8_t *data = bytes;
    uint64_t hash = UINT64_C(14695981039346656037);
    for (NSUInteger i = 0; i < length; i++)
        hash = (hash ^ data[i]) * UINT64_C(1099511628211);
    return (NSUInteger)hash;
}

@interface NV2AMetalProgramKey : NSObject <NSCopying>
@property(nonatomic, readonly) NSData *tokens;
- (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)length;
- (instancetype)initLookup;
- (void)setLookupBytes:(const void *)bytes length:(NSUInteger)length;
- (void)clearLookupBytes;
@end
@implementation NV2AMetalProgramKey {
    const void *_lookupBytes;
    NSUInteger _length, _hash;
    BOOL _lookup;
}
- (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)length
{
    self = [super init];
    if (self) {
        _tokens = [NSData dataWithBytes:bytes length:length];
        if (!_tokens)
            return nil;
        _length = length;
        _hash = program_key_hash(_tokens.bytes, length);
    }
    return self;
}
- (instancetype)initLookup
{
    self = [super init];
    if (self) {
        _lookup = YES;
        _hash = program_key_hash(NULL, 0);
    }
    return self;
}
- (void)setLookupBytes:(const void *)bytes length:(NSUInteger)length
{
    NSAssert(_lookup, @"Stored program keys are immutable");
    _lookupBytes = bytes;
    _length = length;
    _hash = program_key_hash(bytes, length);
}
- (void)clearLookupBytes
{
    [self setLookupBytes:NULL length:0];
}
- (NSUInteger)hash
{
    return _hash;
}
- (BOOL)isEqual:(id)object
{
    if (object == self)
        return YES;
    if (![object isKindOfClass:NV2AMetalProgramKey.class])
        return NO;
    NV2AMetalProgramKey *other = object;
    if (_length != other->_length)
        return NO;
    const void *bytes = _lookup ? _lookupBytes : _tokens.bytes;
    const void *otherBytes =
        other->_lookup ? other->_lookupBytes : other->_tokens.bytes;
    return !_length || !memcmp(bytes, otherBytes, _length);
}
- (id)copyWithZone:(NSZone *)zone
{
    (void)zone;
    return _lookup ? [[NV2AMetalProgramKey alloc] initWithBytes:_lookupBytes
                                                         length:_length] :
                     self;
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

typedef struct NV2AMetalWritableParameterSlot {
    const uint8_t *bytes;
    MTLGPUAddress address;
} NV2AMetalWritableParameterSlot;

@implementation NV2AMetalWritableProgram {
    NV2AMetalCommands *_commands;
    id<MTL4Compiler> _specializationCompiler;
    dispatch_queue_t _specializationQueue;
    id<MTLComputePipelineState> _pipeline, _readonlyPipeline, _rasterPipeline,
        _writableRasterPipeline, _writableRawPipeline, _readonlyRawPipeline;
    id<MTLComputePipelineState> _chainedRasterPipeline, _chainedRawPipeline;
    id<MTLComputePipelineState> _independentPipeline,
        _independentRasterPipeline, _independentRawPipeline;
    id<MTLComputePipelineState> _independentChainedPipeline,
        _independentChainedRasterPipeline, _independentChainedRawPipeline;
    id<MTLLibrary> _interpreterLibrary;
    id<MTL4ArgumentTable> _arguments;
    NV2AMetalDecodedProgram *_decodedProgram;
    NV2AMetalProgramKey *_programLookupKey;
    NV2AMetalLRUCache<NV2AMetalProgramKey *, NV2AMetalDecodedProgram *>
        *_programs;
    NSData *_initialConstants;
    __weak NV2AMetalCommands *_parameterCommands;
    uint64_t _parameterSerial;
    NV2AMetalWritableParameterSlot _parameterSlots[4];
    unsigned _parameterSlotCount, _nextParameterSlot;
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
    MTL4ArgumentTableDescriptor *arguments = [MTL4ArgumentTableDescriptor new];
    arguments.maxBufferBindCount = 7;
    arguments.initializeBindings = YES;
    _arguments = [device newArgumentTableWithDescriptor:arguments error:error];
    /* 64 * 136 * (16 token + 56 decoded) bytes <= 612 KiB payload.
     * This excludes native pipeline objects. Each entry holds at most three;
     * at most two compile jobs retain evicted entries. Commands independently
     * retain buffers/pipelines until GPU completion. */
    _programs = [[NV2AMetalLRUCache alloc] initWithCapacity:64];
    _specializationQueue =
        dispatch_queue_create("org.xemu.metal4.readonly-compile",
                              dispatch_queue_attr_make_with_qos_class(
                                  DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    return _arguments && _programs && _specializationQueue ? self : nil;
}
- (NSData *)snapshotConstants:(const float *)constants
{
    const NSUInteger length =
        sizeof(((NV2AMetalProgramUniforms *)0)->constants);
    @synchronized(self) {
        if (_initialConstants &&
            !memcmp(_initialConstants.bytes, constants, length))
            return _initialConstants;
        NSData *snapshot = [NSData dataWithBytes:constants length:length];
        if (snapshot)
            _initialConstants = snapshot;
        return snapshot;
    }
}
- (MTLGPUAddress)addressForParameters:
                     (const NV2AMetalWritableParameters *)parameters
                             commands:(NV2AMetalCommands *)commands
                                error:(NSError **)error
{
    /* Sealing or cancelling ends the recording before its upload arena can
     * be rewound. Within it, each registered upload remains immutable. */
    uint64_t serial = commands.recordingSerial;
    if (_parameterCommands != commands || _parameterSerial != serial) {
        _parameterCommands = commands;
        _parameterSerial = serial;
        _parameterSlotCount = _nextParameterSlot = 0;
    }
    for (unsigned i = 0; i < _parameterSlotCount; i++) {
        NV2AMetalWritableParameterSlot slot = _parameterSlots[i];
        if (!memcmp(slot.bytes, parameters, sizeof(*parameters)))
            return slot.address;
    }
    NSUInteger offset;
    id<MTLBuffer> buffer = [commands uploadBytes:parameters
                                          length:sizeof(*parameters)
                                          offset:&offset
                                           error:error];
    if (!buffer)
        return 0;
    MTLGPUAddress address = buffer.gpuAddress + offset;
    _parameterSlots[_nextParameterSlot] = (NV2AMetalWritableParameterSlot){
        (const uint8_t *)buffer.contents + offset, address
    };
    unsigned capacity = sizeof(_parameterSlots) / sizeof(*_parameterSlots);
    _nextParameterSlot = (_nextParameterSlot + 1) % capacity;
    _parameterSlotCount = MIN(_parameterSlotCount + 1, capacity);
    return address;
}
- (id<MTLComputePipelineState>)interpreterPipelineWithWrites:(BOOL)write
                                                     compact:(BOOL)compact
                                                     discard:(BOOL)discard
                                                     chained:(BOOL)chained
                                                 independent:(BOOL)independent
                                                       error:(NSError **)error
{
    id<MTLComputePipelineState> __strong *slot;
    NSString *functionName;
    if (independent) {
        if (chained) {
            slot = discard ? &_independentChainedRawPipeline :
                   compact ? &_independentChainedRasterPipeline :
                             &_independentChainedPipeline;
            functionName =
                discard ? @"nv2a_independent_writable_raw_program_chained" :
                compact ? @"nv2a_independent_writable_raster_program_chained" :
                          @"nv2a_independent_writable_program_chained";
        } else {
            slot = discard ? &_independentRawPipeline :
                   compact ? &_independentRasterPipeline :
                             &_independentPipeline;
            functionName =
                discard ? @"nv2a_independent_writable_raw_program" :
                compact ? @"nv2a_independent_writable_raster_program" :
                          @"nv2a_independent_writable_program";
        }
    } else if (chained) {
        slot = discard ? &_chainedRawPipeline : &_chainedRasterPipeline;
        functionName = discard ? @"nv2a_writable_chained_raw_program" :
                                 @"nv2a_writable_chained_raster_program";
    } else if (discard) {
        slot = write ? &_writableRawPipeline : &_readonlyRawPipeline;
        functionName =
            write ? @"nv2a_writable_raw_program" : @"nv2a_readonly_raw_program";
    } else if (write) {
        slot = compact ? &_writableRasterPipeline : &_pipeline;
        functionName = compact ? @"nv2a_writable_raster_program" :
                                 @"nv2a_writable_program";
    } else {
        slot = compact ? &_rasterPipeline : &_readonlyPipeline;
        functionName = compact ? @"nv2a_readonly_raster_program" :
                                 @"nv2a_readonly_program";
    }
    if (*slot)
        return *slot;
    if (!_interpreterLibrary) {
        id<MTLDevice> device = _commands.device;
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
        _interpreterLibrary = library;
        _specializationCompiler = compiler;
    }
    MTL4LibraryFunctionDescriptor *function =
        [MTL4LibraryFunctionDescriptor new];
    function.library = _interpreterLibrary;
    function.name = functionName;
    MTL4ComputePipelineDescriptor *descriptor =
        [MTL4ComputePipelineDescriptor new];
    descriptor.computeFunctionDescriptor = function;
    *slot = [_specializationCompiler
        newComputePipelineStateWithDescriptor:descriptor
                          compilerTaskOptions:nil
                                        error:error];
    return *slot;
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
    NV2AMetalProgramKey *lookup = _programLookupKey;
    if (!lookup) {
        lookup = [[NV2AMetalProgramKey alloc] initLookup];
        _programLookupKey = lookup;
    }
    NV2AMetalDecodedProgram *cached = nil;
    if (lookup) {
        @try {
            [lookup setLookupBytes:tokens length:bytes];
            cached = _programs[lookup];
        } @finally {
            [lookup clearLookupBytes];
        }
        if (cached) {
            _decodedProgram = cached;
            return cached;
        }
    }
    /* Lookup allocation is optional. A miss or missing lookup object uses the
     * original owning snapshot; only the latter still needs its LRU read. */
    NV2AMetalProgramKey *key =
        [[NV2AMetalProgramKey alloc] initWithBytes:tokens length:bytes];
    if (!key) {
        program_error(error, @"Cannot snapshot native vertex program");
        return nil;
    }
    if (!lookup) {
        cached = _programs[key];
        if (cached) {
            _decodedProgram = cached;
            return cached;
        }
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
                                             attributeFetch:nil
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
               attributeFetch:nil
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
    return [self encodeProgram:program
                      uniforms:uniforms
               attributeBuffer:attributes
                         first:first
                         count:count
                        access:access
                   writeEnable:writeEnable
                     rasterize:rasterize
              compactRegisters:compact
                attributeFetch:nil
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
      attributeFetch:(NV2AMetalFetchResult *)fetch
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
               attributeFetch:fetch
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
    return [self encodeSerialProgram:program
                            uniforms:uniforms
                     attributeBuffer:attributes
                               first:first
                               count:count
                              access:access
                           rasterize:rasterize
                            previous:previous
                      attributeFetch:nil
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
         attributeFetch:(NV2AMetalFetchResult *)fetch
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
               attributeFetch:fetch
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
      attributeFetch:(NV2AMetalFetchResult *)fetch
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
    NV2AMetalWritableParameters parameters = { 0 };
    parameters.common = *uniforms;
    parameters.common.vertex_count = (unsigned)count;
    parameters.common.program_length = (unsigned)decoded.slots;
    parameters.full_access = access;
    parameters.write_enable = writeEnable;
    parameters.rasterize = rasterize;
    BOOL discard = compact && !rasterize;
    /* Preserve the static fast path. A chained numerical refinement also
     * needs unchanged address inputs from its known initial GPU baseline.
     * The kernel still consumes the real predecessor context and fault. */
    BOOL independent =
        writeEnable && [validated hasIndependentConstantWrites:access];
    BOOL refinable =
        writeEnable && !independent && validated &&
        (!previous ||
         [previous
             canRefineConstantsForProgram:validated
                                constants:&parameters.common.constants[0][0]
                                 commands:commands]);
    if (refinable)
        independent = [validated
            hasIndependentConstantWrites:access
                               constants:&parameters.common.constants[0][0]];
    if (refinable && !independent && count &&
        [fetch isMemberOfClass:NV2AMetalFetchResult.class]) {
        NV2AMetalFetchUniforms sourceUniforms;
        if ([fetch getReadonlyProofUniforms:&sourceUniforms
                            attributeBuffer:attributes
                                      first:first
                                      count:count
                                   commands:commands]) {
            NSData *summaries = nil;
            uint64_t laneMask = 0;
            BOOL summarized =
                [fetch getFloatProofSummaries:&summaries
                                     laneMask:&laneMask
                              attributeBuffer:attributes
                                        first:first
                                        count:count
                                     commands:commands] &&
                (laneMask & validated.readonlyProofAttributeLanes64);
            independent =
                summarized ?
                    [validated
                        refineIndependentConstantWrites:access
                                              constants:&parameters.common
                                                             .constants[0][0]
                                         sourceUniforms:&sourceUniforms
                                         floatSummaries:summaries
                                               laneMask:laneMask] :
                    [validated
                        refineIndependentConstantWrites:access
                                              constants:&parameters.common
                                                             .constants[0][0]
                                         sourceUniforms:&sourceUniforms];
        }
    }
    id<MTLComputePipelineState> pipeline =
        [self interpreterPipelineWithWrites:writeEnable
                                    compact:compact
                                    discard:discard
                                    chained:previous != nil
                                independent:independent
                                      error:error];
    if (!pipeline)
        return nil;
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
    MTLGPUAddress parameterAddress = [self addressForParameters:&parameters
                                                       commands:commands
                                                          error:error];
    if (!parameterAddress) {
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
    id<MTLBuffer> buffers[] = { inputs, raw, vertices, nil, program };
    for (unsigned i = 0; i < 5; i++) {
        if (i != 3 && buffers[i] &&
            ![commands addResource:buffers[i] error:error]) {
            return nil;
        }
        NSUInteger offset =
            i == 0 && count ? first * sizeof(NV2AMetalProgramInput) : 0;
        [_arguments setAddress:i == 3 ? parameterAddress :
                                        buffers[i].gpuAddress + offset
                       atIndex:i];
    }
    if (context && ![commands addResource:context error:error])
        return nil;
    [_arguments setAddress:context.gpuAddress atIndex:5];
    id<MTLBuffer> prior = previous.serialContext;
    if (prior && ![commands addResource:prior error:error])
        return nil;
    [_arguments setAddress:prior.gpuAddress atIndex:6];
    if (!writeEnable && count)
        pipeline = [self readonlyPipelineForProgram:decoded
                                            compact:compact
                                            discard:discard];
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
    NSUInteger threads = writeEnable && !independent ? 1 : MAX(count, 1u);
    NSUInteger width = writeEnable && !independent ?
                           1 :
                           MIN(threads, pipeline.threadExecutionWidth);
    [encoder dispatchThreads:MTLSizeMake(threads, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
    [encoder barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    BOOL faultFreeReadOnly = NO;
    if (compact && !writeEnable && validated) {
        faultFreeReadOnly = [validated hasFaultFreeReadOnlyAccess:access];
        if (!faultFreeReadOnly) {
            NV2AMetalFetchUniforms sourceUniforms;
            BOOL bound = validated.readAttributes &&
                         [fetch isMemberOfClass:NV2AMetalFetchResult.class] &&
                         [fetch getReadonlyProofUniforms:&sourceUniforms
                                         attributeBuffer:attributes
                                                   first:first
                                                   count:count
                                                commands:commands];
            NSData *summaries = nil;
            uint64_t laneMask = 0;
            BOOL summarized =
                bound &&
                [fetch getFloatProofSummaries:&summaries
                                     laneMask:&laneMask
                              attributeBuffer:attributes
                                        first:first
                                        count:count
                                     commands:commands] &&
                (laneMask & validated.readonlyProofAttributeLanes64);
            faultFreeReadOnly =
                summarized ?
                    [validated hasFaultFreeReadOnlyAccess:access
                                                constants:&parameters.common
                                                               .constants[0][0]
                                           sourceUniforms:&sourceUniforms
                                           floatSummaries:summaries
                                                 laneMask:laneMask] :
                    [validated
                        hasFaultFreeReadOnlyAccess:access
                                         constants:&parameters.common
                                                        .constants[0][0]
                                    sourceUniforms:bound ? &sourceUniforms :
                                                           NULL];
        }
    }
    if (writeEnable)
        return [[NV2AMetalWritableEncoding alloc] initRaw:raw
                                                 vertices:vertices
                                                  context:context
                                               parameters:&parameters
                                                  compact:compact
                                        faultFreeReadOnly:faultFreeReadOnly
                                         validatedProgram:validated
                                                 previous:previous
                                                 commands:commands];
    return [[NV2AMetalWritableEncoding alloc] initRaw:raw
                                             vertices:vertices
                                              context:context
                                           parameters:&parameters
                                constantSnapshotOwner:self
                                              compact:compact
                                    faultFreeReadOnly:faultFreeReadOnly
                                     validatedProgram:validated
                                             previous:previous
                                             commands:commands];
}
@end
