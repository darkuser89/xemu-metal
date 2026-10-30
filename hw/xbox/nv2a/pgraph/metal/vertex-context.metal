/* Native XF context execution.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
void state_write(thread VPRegisters &r, uint index, float4 value, uint mask)
{
    if (index >= 192 ||
        (!r.full_access && index < 96 && index != 58 && index != 59)) {
        r.fault = NV2AMetalProgramFaultConstantRange;
        return;
    }
    vp_write(r.constants[index], value, mask, false);
    if (mask)
        r.dirty[index] = 1;
}

void writable_write(thread VPRegisters &r, uint destination, float4 value,
                    uint mask, bool enable)
{
    if (destination & 256u)
        vp_write(r.output[destination & 255u], value, mask,
                 (destination & 255u) == 5);
    else if (enable)
        state_write(r, destination, value, mask);
}
void writable_write(thread VPReadOnlyRegisters &r, uint destination,
                    float4 value, uint mask, bool)
{
    if (destination & 256u)
        vp_write(r.output[destination & 255u], value, mask,
                 (destination & 255u) == 5);
}
template <typename Registers>
inline __attribute__((always_inline))
void writable_step(constant NV2AMetalProgramInstruction &op,
                   constant NV2AMetalProgramUniforms &u,
                   device const NV2AMetalProgramInput &input,
                   thread Registers &r, bool write_enable)
{
    bool paired = op.mac != NV2AMetalMACNop && op.ilu != NV2AMetalILUNop;
    uint mac_mask = paired && op.temp_register == 1 ? 0 : op.mac_mask;
    float4 mac(0), ilu(0);
    int address = r.address;
    /* All operand reads precede the instruction's output/temp writes.
     * R12 mirrors oPos, so reevaluating an operand after writing oPos
     * changes this instruction's result and violates the source snapshot.
     */
    if (op.mac == NV2AMetalMACArl) {
        float a = vp_source(0, op, u, input, r, false).x;
        float rounded = floor(a + 0.001f);
        if (!isfinite(rounded) || rounded < -2147483648.0f ||
            rounded >= 2147483648.0f)
            r.fault = NV2AMetalProgramFaultAddressRange;
        else
            address = int(rounded);
    } else if (op.mac != NV2AMetalMACNop) {
        mac = vp_mac_inputs(op, u, input, r);
    }
    if (op.ilu != NV2AMetalILUNop) {
        bool scalar =
            op.ilu >= NV2AMetalILURcp && op.ilu <= NV2AMetalILULog;
        ilu = vp_ilu(op.ilu, vp_source(2, op, u, input, r, scalar));
    }
    if (r.fault)
        return;
    if (op.output_mask) {
        if (op.output_mux == 0 && op.mac != NV2AMetalMACNop &&
            op.mac != NV2AMetalMACArl)
            writable_write(r, op.output_register, mac, op.output_mask,
                           write_enable);
        else if (op.output_mux == 1 && op.ilu != NV2AMetalILUNop)
            writable_write(r, op.output_register, ilu, op.output_mask,
                           write_enable);
    }
    if (op.ilu != NV2AMetalILUNop && op.ilu_mask)
        vp_write_temporary(r, paired ? 1 : op.temp_register, ilu,
                           op.ilu_mask);
    if (op.mac == NV2AMetalMACArl)
        r.address = address;
    else if (op.mac != NV2AMetalMACNop && mac_mask)
        vp_write_temporary(r, op.temp_register, mac, mac_mask);
}
template <typename Registers>
void writable_execute(constant NV2AMetalProgramInstruction *program,
                      constant NV2AMetalProgramUniforms &u,
                      device const NV2AMetalProgramInput &input,
                      thread Registers &r, bool write_enable)
{
    for (uint slot = 0; slot < u.program_length && !r.fault; slot++)
        writable_step(program[slot], u, input, r, write_enable);
}
template <bool Compact, bool OmitRaw = false, bool OmitRaster = false,
          typename Registers>
static void writable_store(thread const Registers &r,
                           constant NV2AMetalProgramUniforms &u,
                           device NV2AMetalProgramOutput *raw,
                           device NV2AMetalVertex *vertices, uint vertex_index,
                           bool rasterize)
{
    if (OmitRaw) {
        /* Serial XF reports its first fault through the context below. */
    } else if (Compact) {
        if (r.fault)
            atomic_fetch_or_explicit((device atomic_uint *)raw, r.fault,
                                     memory_order_relaxed);
    } else {
        NV2AMetalProgramOutput snapshot = {};
        for (uint row = 0; row < 13; row++)
            vp_store4(snapshot.registers[row], r.output[row]);
        snapshot.fault = r.fault;
        raw[vertex_index] = snapshot;
    }
    /* Compact raw XF retains faults/context, but has no raster output. */
    if (OmitRaster)
        return;
    NV2AMetalVertex result = {};
    if (r.fault) {
        /* Poisoned vertices are never a substitute for handling the fault.
         */
        vertices[vertex_index] = result;
        return;
    }
    if (!rasterize) {
        vertices[vertex_index] = result;
        return;
    }
    float4 position = r.output[0];
    position.xy = trunc(position.xy * 16.0f) / 16.0f;
    position.w = vp_clamp_w(position.w);
    vp_store4(result.screen, position);
    for (uint p = 0; p < 3; p++) {
        vp_store4(result.plane[p], position);
    }
    float2 size(u.surface_size[0], u.surface_size[1]);
    float2 ndc = (2.0f * position.xy - size) / size;
    vp_store4(result.clip,
              float4(ndc.x, -ndc.y, position.z / u.zmax, 1) * position.w);
    vp_store4(result.color[0], vp_color(r.output[3]));
    vp_store4(result.color[2], vp_color(r.output[7]));
    for (uint s = 0; s < 2; s++) {
        float4 specular = u.specular_enable ?
                              vp_color(r.output[s == 0 ? 4 : 8]) :
                              float4(0, 0, 0, 1);
        if (u.ignore_specular_alpha) {
            specular.w = 1;
        }
        vp_store4(result.color[1 + 2 * s], specular);
    }
    for (uint t = 0; t < 4; t++) {
        vp_store4(result.texcoord[t], r.output[9 + t]);
    }
    result.fog = vp_fog(r.output[5].x, u);
    result.point_size =
        u.point_programmed ?
            r.output[6].x :
            (u.point_size <= 0 ? 1.0f : u.point_size) * u.point_scale;
    vertices[vertex_index] = result;
}

template <bool Compact, bool OmitRaster = false, bool Chained = false>
static void
writable_program(device const NV2AMetalProgramInput *inputs,
                 device NV2AMetalProgramOutput *raw,
                 device NV2AMetalVertex *vertices,
                 constant NV2AMetalWritableParameters &parameters,
                 constant NV2AMetalProgramInstruction *program,
                 device NV2AMetalWritableContext *context, uint index,
                 device const NV2AMetalWritableContext *previous = nullptr)
{
    if (index != 0)
        return;
    constant NV2AMetalProgramUniforms &u = parameters.common;
    VPRegisters r;
    r.full_access = parameters.full_access != 0;
    r.fault = Chained ? previous->fault : 0;
    for (uint row = 0; row < 192; row++) {
        r.constants[row] =
            Chained ?
                float4(previous->constants[row][0], previous->constants[row][1],
                       previous->constants[row][2],
                       previous->constants[row][3]) :
                float4(u.constants[row][0], u.constants[row][1],
                       u.constants[row][2], u.constants[row][3]);
        r.dirty[row] = 0;
    }
    for (uint vertex_index = 0; vertex_index < u.vertex_count && !r.fault;
         vertex_index++) {
        r.address = 0;
        for (uint row = 0; row < 12; row++)
            r.temporary[row] = float4(0);
        for (uint row = 0; row < 13; row++)
            r.output[row] = float4(0, 0, 0, 1);
        writable_execute(program, u, inputs[vertex_index], r,
                         parameters.write_enable != 0);
        writable_store<false, Compact, OmitRaster>(
            r, u, raw, vertices, vertex_index, parameters.rasterize);
    }
    NV2AMetalWritableContext result = {};
    for (uint row = 0; row < 192; row++) {
        vp_store4(result.constants[row], r.constants[row]);
        result.dirty[row] = r.dirty[row];
    }
    result.fault = r.fault;
    context[0] = result;
}

kernel void nv2a_writable_program(
    device const NV2AMetalProgramInput *inputs [[buffer(0)]],
    device NV2AMetalProgramOutput *raw [[buffer(1)]],
    device NV2AMetalVertex *vertices [[buffer(2)]],
    constant NV2AMetalWritableParameters &parameters [[buffer(3)]],
    constant NV2AMetalProgramInstruction *program [[buffer(4)]],
    device NV2AMetalWritableContext *context [[buffer(5)]],
    uint index [[thread_position_in_grid]])
{
    writable_program<false>(inputs, raw, vertices, parameters, program, context,
                            index);
}
kernel void nv2a_writable_raster_program(
    device const NV2AMetalProgramInput *inputs [[buffer(0)]],
    device NV2AMetalVertex *vertices [[buffer(2)]],
    constant NV2AMetalWritableParameters &parameters [[buffer(3)]],
    constant NV2AMetalProgramInstruction *program [[buffer(4)]],
    device NV2AMetalWritableContext *context [[buffer(5)]],
    uint index [[thread_position_in_grid]])
{
    writable_program<true>(inputs, nullptr, vertices, parameters, program,
                           context, index);
}

kernel void nv2a_writable_raw_program(
    device const NV2AMetalProgramInput *inputs [[buffer(0)]],
    constant NV2AMetalWritableParameters &parameters [[buffer(3)]],
    constant NV2AMetalProgramInstruction *program [[buffer(4)]],
    device NV2AMetalWritableContext *context [[buffer(5)]],
    uint index [[thread_position_in_grid]])
{
    writable_program<true, true>(inputs, nullptr, nullptr, parameters, program,
                                 context, index);
}

kernel void nv2a_writable_chained_raster_program(
    device const NV2AMetalProgramInput *inputs [[buffer(0)]],
    device NV2AMetalVertex *vertices [[buffer(2)]],
    constant NV2AMetalWritableParameters &parameters [[buffer(3)]],
    constant NV2AMetalProgramInstruction *program [[buffer(4)]],
    device NV2AMetalWritableContext *context [[buffer(5)]],
    device const NV2AMetalWritableContext *previous [[buffer(6)]],
    uint index [[thread_position_in_grid]])
{
    writable_program<true, false, true>(inputs, nullptr, vertices, parameters,
                                        program, context, index, previous);
}
kernel void nv2a_writable_chained_raw_program(
    device const NV2AMetalProgramInput *inputs [[buffer(0)]],
    constant NV2AMetalWritableParameters &parameters [[buffer(3)]],
    constant NV2AMetalProgramInstruction *program [[buffer(4)]],
    device NV2AMetalWritableContext *context [[buffer(5)]],
    device const NV2AMetalWritableContext *previous [[buffer(6)]],
    uint index [[thread_position_in_grid]])
{
    writable_program<true, true, true>(inputs, nullptr, nullptr, parameters,
                                       program, context, index, previous);
}

/* With XFCTX writes disabled, each vertex starts from the same immutable
 * constants and resets its temporary/output/address registers independently.
 * Host validation still checks every fault before exposing any result. */
struct NV2AMetalReadonlyInterpreter {
    static void execute(constant NV2AMetalProgramInstruction *program,
                        constant NV2AMetalProgramUniforms &u,
                        device const NV2AMetalProgramInput &input,
                        thread VPReadOnlyRegisters &r)
    {
        writable_execute(program, u, input, r, false);
    }
};
template <bool Compact, typename Executor = NV2AMetalReadonlyInterpreter,
          bool OmitRaster = false>
static void readonly_program(device const NV2AMetalProgramInput *inputs,
                             device NV2AMetalProgramOutput *raw,
                             device NV2AMetalVertex *vertices,
                             constant NV2AMetalWritableParameters &parameters,
                             constant NV2AMetalProgramInstruction *program,
                             uint index)
{
    constant NV2AMetalProgramUniforms &u = parameters.common;
    if (index >= u.vertex_count)
        return;
    VPReadOnlyRegisters r;
    r.full_access = parameters.full_access != 0;
    r.address = 0;
    r.fault = 0;
    /* Constants remain in the immutable uniform buffer; this context has no
     * per-vertex constant copy or dirty array. Aperture checks are shared. */
    for (uint row = 0; row < 12; row++)
        r.temporary[row] = float4(0);
    for (uint row = 0; row < 13; row++)
        r.output[row] = float4(0, 0, 0, 1);
    Executor::execute(program, u, inputs[index], r);
    writable_store<Compact, false, OmitRaster>(r, u, raw, vertices, index,
                                               parameters.rasterize);
}

/* Reused by generated specialized entry points. The instruction executor is
 * the only variation; register initialization, raw/fault and raster stores
 * remain the same implementation. */
#define NV2A_METAL_READONLY_ENTRY(Name, Compact, Executor)                     \
kernel void Name(                                                            \
    device const NV2AMetalProgramInput *inputs [[buffer(0)]],                  \
    device NV2AMetalProgramOutput *raw [[buffer(1)]],                          \
    device NV2AMetalVertex *vertices [[buffer(2)]],                            \
    constant NV2AMetalWritableParameters &parameters [[buffer(3)]],            \
    constant NV2AMetalProgramInstruction *program [[buffer(4)]],               \
    uint index [[thread_position_in_grid]])                                   \
{                                                                            \
    readonly_program<Compact, Executor>(inputs, raw, vertices, parameters,     \
                                       program, index);                      \
}
NV2A_METAL_READONLY_ENTRY(nv2a_readonly_program, false,
                         NV2AMetalReadonlyInterpreter)
NV2A_METAL_READONLY_ENTRY(nv2a_readonly_raster_program, true,
                         NV2AMetalReadonlyInterpreter)

#define NV2A_METAL_READONLY_RAW_ENTRY(Name, Executor)                       \
    kernel void Name(                                                       \
        device const NV2AMetalProgramInput *inputs [[buffer(0)]],           \
        device NV2AMetalProgramOutput *raw [[buffer(1)]],                   \
        constant NV2AMetalWritableParameters &parameters [[buffer(3)]],     \
        constant NV2AMetalProgramInstruction *program [[buffer(4)]],        \
        uint index [[thread_position_in_grid]])                             \
    {                                                                       \
        readonly_program<true, Executor, true>(inputs, raw, nullptr,        \
                                               parameters, program, index); \
    }
NV2A_METAL_READONLY_RAW_ENTRY(nv2a_readonly_raw_program,
                              NV2AMetalReadonlyInterpreter)

kernel void
nv2a_state_program(device const NV2AMetalStateInput *inputs [[buffer(0)]],
                   device NV2AMetalStateOutput *outputs [[buffer(1)]],
                   constant NV2AMetalStateParameters &parameters [[buffer(2)]],
                   constant NV2AMetalProgramInstruction *program [[buffer(3)]],
                   uint index [[thread_position_in_grid]])
{
    constant NV2AMetalProgramUniforms &u = parameters.common;
    if (index >= u.vertex_count)
        return;
    VPRegisters r;
    r.address = 0;
    r.fault = 0;
    r.full_access = parameters.full_access != 0;
    for (uint i = 0; i < 192; i++) {
        r.constants[i] = float4(
            inputs[index].constants[i][0], inputs[index].constants[i][1],
            inputs[index].constants[i][2], inputs[index].constants[i][3]);
        r.dirty[i] = 0;
    }
    for (uint i = 0; i < 12; i++)
        r.temporary[i] = float4(0);
    for (uint i = 0; i < 13; i++)
        r.output[i] = float4(0, 0, 0, 1);
    writable_execute(program, u, inputs[index].attributes, r, true);
    NV2AMetalStateOutput result = {};
    for (uint i = 0; i < 192; i++) {
        vp_store4(result.constants[i], r.constants[i]);
        result.dirty[i] = r.dirty[i];
    }
    result.fault = r.fault;
    outputs[index] = result;
}
