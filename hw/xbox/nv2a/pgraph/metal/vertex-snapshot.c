/* Native vertex input snapshots; the legacy vertex-attr VMSD is empty.
 * SPDX-License-Identifier: LGPL-2.0-or-later */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "qemu/osdep.h"
#include "hw/xbox/nv2a/nv2a_int.h"
#pragma clang diagnostic pop
#include "migration/qemu-file.h"
#include "qemu/bswap.h"
#include "vertex-snapshot.h"
#include "renderer.h"

#define FIXED_FLOAT_FIELDS(X)     \
    X(material_alpha)             \
    X(light_infinite_half_vector) \
    X(light_infinite_direction)   \
    X(light_local_position)       \
    X(light_local_attenuation)    \
    X(specular_params)            \
    X(specular_power)             \
    X(specular_params_back)       \
    X(specular_power_back)        \
    X(point_params)

typedef struct FixedSnapshot {
#define DECLARE_FIELD(name) typeof_field(PGRAPHState, name) name;
    FIXED_FLOAT_FIELDS(DECLARE_FIELD)
#undef DECLARE_FIELD
    bool texture_matrix_enable[4];
    float material_alpha_back;
} FixedSnapshot;

static const struct {
    size_t live, staged, bytes;
} fixed_fields[] = {
#define FIELD_OFFSETS(name)                                       \
    { offsetof(PGRAPHState, name), offsetof(FixedSnapshot, name), \
      sizeof(((PGRAPHState *)0)->name) },
    FIXED_FLOAT_FIELDS(FIELD_OFFSETS)
#undef FIELD_OFFSETS
};
#undef FIXED_FLOAT_FIELDS
G_STATIC_ASSERT(sizeof(float) == sizeof(uint32_t));

static bool valid_attribute(const VertexAttribute *a)
{
    if (a->offset > 0x7fffffff || a->stride > 255 || a->count > 4) {
        return false;
    }
    if (!a->size && !a->count && !a->format) {
        return true; /* Unconfigured attribute after PGRAPH initialization. */
    }
    switch (a->format) {
    case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_D3D:
        return a->size == 1 && a->count == 4;
    case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_UB_OGL:
        return a->size == 1;
    case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S1:
    case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_S32K:
        return a->size == 2;
    case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_F:
        return a->size == 4;
    case NV097_SET_VERTEX_DATA_ARRAY_FORMAT_TYPE_CMP:
        return a->size == 4 && a->count == 1;
    default:
        return false;
    }
}

static void put_float(QEMUFile *f, const float *value)
{
    uint32_t bits;
    memcpy(&bits, value, sizeof(bits));
    qemu_put_be32(f, bits);
}

static void get_float(QEMUFile *f, float *value)
{
    uint32_t bits = qemu_get_be32(f);
    memcpy(value, &bits, sizeof(bits));
}

static int vertex_put(QEMUFile *f, void *pv, size_t size,
                      const VMStateField *field, JSONWriter *vmdesc)
{
    PGRAPHState *pg = pv;
    (void)size;
    (void)field;
    (void)vmdesc;
    if (pg->inline_buffer_length > NV2A_MAX_BATCH_LENGTH) {
        return -EINVAL;
    }
    for (unsigned i = 0; i < NV2A_VERTEXSHADER_ATTRIBUTES; i++) {
        const VertexAttribute *a = &pg->vertex_attributes[i];
        if (!valid_attribute(a) ||
            (a->inline_buffer_populated && pg->inline_buffer_length &&
             !a->inline_buffer)) {
            return -EINVAL;
        }
    }
    /* Escape cannot collide with a valid v1 inline count. This is a host
     * packet version, not an NV2A register or vertex-format definition. */
    qemu_put_be32(f, UINT32_MAX);
    qemu_put_be32(f, 4);
    qemu_put_be32(f, pg->inline_buffer_length);
    qemu_put_be16(f, pg->compressed_attrs);
    qemu_put_be16(f, pg->uniform_attrs);
    qemu_put_be16(f, pg->swizzle_attrs);
    qemu_put_be32(f, pg->draw_arrays_min_start);
    qemu_put_byte(f, pg->draw_arrays_prevent_connect);
    for (unsigned i = 0; i < NV2A_VERTEXSHADER_ATTRIBUTES; i++) {
        const VertexAttribute *a = &pg->vertex_attributes[i];
        qemu_put_byte(f, a->dma_select);
        qemu_put_be64(f, a->offset);
        qemu_put_be32(f, a->inline_array_offset);
        qemu_put_be32(f, a->format);
        qemu_put_be32(f, a->size);
        qemu_put_be32(f, a->count);
        qemu_put_be32(f, a->stride);
        for (unsigned c = 0; c < 4; c++) {
            put_float(f, &a->inline_value[c]);
        }
        qemu_put_byte(f, a->needs_conversion);
        qemu_put_byte(f, a->inline_buffer_populated);
        if (a->inline_buffer_populated) {
            for (unsigned j = 0; j < pg->inline_buffer_length * 4; j++) {
                put_float(f, &a->inline_buffer[j]);
            }
        }
    }
    for (unsigned i = 0; i < ARRAY_SIZE(fixed_fields); i++) {
        const uint8_t *base = (const uint8_t *)pg + fixed_fields[i].live;
        for (size_t j = 0; j < fixed_fields[i].bytes; j += 4) {
            put_float(f, (const float *)(base + j));
        }
    }
    for (unsigned i = 0; i < 4; i++) {
        qemu_put_byte(f, pg->texture_matrix_enable[i]);
    }
    put_float(f, &pg->material_alpha_back);
    qemu_put_byte(f, pg->enable_vertex_program_write);
    return qemu_file_get_error(f);
}

static int vertex_get(QEMUFile *f, void *pv, size_t size,
                      const VMStateField *field)
{
    PGRAPHState *pg = pv;
    VertexAttribute staged[NV2A_VERTEXSHADER_ATTRIBUTES] = { 0 };
    FixedSnapshot fixed = { 0 };
    bool write_enable = false;
    int ret = -EINVAL;
    (void)size;
    (void)field;
    uint32_t length = qemu_get_be32(f);
    bool has_fixed = length == UINT32_MAX;
    uint32_t version = 1;
    if (has_fixed) {
        version = qemu_get_be32(f);
        if (version < 2 || version > 4) {
            return -EINVAL;
        }
        length = qemu_get_be32(f);
    }
    if (length > NV2A_MAX_BATCH_LENGTH || length != pg->inline_buffer_length) {
        return -EINVAL;
    }
    uint16_t compressed = qemu_get_be16(f), uniform = qemu_get_be16(f),
             swizzle = qemu_get_be16(f);
    uint32_t minimum = qemu_get_be32(f);
    unsigned prevent = qemu_get_byte(f);
    if (prevent > 1) {
        return -EINVAL;
    }
    for (unsigned i = 0; i < NV2A_VERTEXSHADER_ATTRIBUTES; i++) {
        VertexAttribute *a = &staged[i];
        unsigned dma = qemu_get_byte(f);
        a->dma_select = dma;
        a->offset = qemu_get_be64(f);
        a->inline_array_offset = qemu_get_be32(f);
        a->format = qemu_get_be32(f);
        a->size = qemu_get_be32(f);
        a->count = qemu_get_be32(f);
        a->stride = qemu_get_be32(f);
        for (unsigned c = 0; c < 4; c++) {
            get_float(f, &a->inline_value[c]);
        }
        unsigned conversion = qemu_get_byte(f), populated = qemu_get_byte(f);
        a->needs_conversion = conversion;
        a->inline_buffer_populated = populated;
        if (dma > 1 || conversion > 1 || populated > 1 || !valid_attribute(a) ||
            (populated && length && !pg->vertex_attributes[i].inline_buffer)) {
            goto out;
        }
        if (populated && length) {
            a->inline_buffer = g_new(float, length * 4);
            for (unsigned j = 0; j < length * 4; j++) {
                get_float(f, &a->inline_buffer[j]);
                if (qemu_file_get_error(f)) {
                    goto out;
                }
            }
        }
        if (qemu_file_get_error(f)) {
            goto out;
        }
    }
    if (has_fixed) {
        for (unsigned i = 0; i < ARRAY_SIZE(fixed_fields); i++) {
            uint8_t *base = (uint8_t *)&fixed + fixed_fields[i].staged;
            for (size_t j = 0; j < fixed_fields[i].bytes; j += 4) {
                get_float(f, (float *)(base + j));
            }
        }
        for (unsigned i = 0; i < 4; i++) {
            unsigned enabled = qemu_get_byte(f);
            if (enabled > 1) {
                goto out;
            }
            fixed.texture_matrix_enable[i] = enabled;
        }
        if (version >= 3) {
            get_float(f, &fixed.material_alpha_back);
        }
        if (version >= 4) {
            unsigned enabled = qemu_get_byte(f);
            if (enabled > 1) {
                goto out;
            }
            write_enable = enabled;
        }
    }
    if (qemu_file_get_error(f)) {
        goto out;
    }
    /* Commit only after every attribute and payload has passed validation.
     * PGRAPH owns the destination buffers; no saved pointer is imported. */
    for (unsigned i = 0; i < NV2A_VERTEXSHADER_ATTRIBUTES; i++) {
        float *buffer = pg->vertex_attributes[i].inline_buffer;
        if (staged[i].inline_buffer) {
            memcpy(buffer, staged[i].inline_buffer, length * 16);
        }
        VertexAttribute restored = staged[i];
        restored.inline_buffer = buffer;
        pg->vertex_attributes[i] = restored;
    }
    pg->compressed_attrs = compressed;
    pg->uniform_attrs = uniform;
    pg->swizzle_attrs = swizzle;
    pg->draw_arrays_min_start = minimum;
    pg->draw_arrays_prevent_connect = prevent;
    if (has_fixed) {
        for (unsigned i = 0; i < ARRAY_SIZE(fixed_fields); i++) {
            memcpy((uint8_t *)pg + fixed_fields[i].live,
                   (const uint8_t *)&fixed + fixed_fields[i].staged,
                   fixed_fields[i].bytes);
        }
        pg->material_alpha_back = fixed.material_alpha_back;
        memcpy(pg->texture_matrix_enable, fixed.texture_matrix_enable,
               sizeof(fixed.texture_matrix_enable));
    }
    /* Old packets lack the live WriteEnable policy. A frozen active vertex
     * capture cannot supply it for the next Begin. */
    if (version >= 4) {
        pg->enable_vertex_program_write = write_enable;
    }
    ret = 0;
out:
    for (unsigned i = 0; i < NV2A_VERTEXSHADER_ATTRIBUTES; i++) {
        g_free(staged[i].inline_buffer);
    }
    return ret;
}

static const VMStateInfo vertex_info = {
    .name = "metal4-vertex-inputs",
    .get = vertex_get,
    .put = vertex_put,
};

static bool vertex_needed(void *opaque)
{
    NV2AState *d = opaque;
    return !d->pgraph.renderer ||
           d->pgraph.renderer->type == CONFIG_DISPLAY_RENDERER_METAL4;
}

const VMStateDescription vmstate_nv2a_metal4_vertices = {
    .name = "nv2a/metal4-vertices",
    .version_id = 1,
    .minimum_version_id = 1,
    .needed = vertex_needed,
    .fields = (VMStateField[]){ {
                                    .name = "vertex-inputs",
                                    .size = sizeof(PGRAPHState),
                                    .info = &vertex_info,
                                    .flags = VMS_SINGLE,
                                    .offset = offsetof(NV2AState, pgraph),
                                },
                                VMSTATE_END_OF_LIST() },
};

static bool vertex_capture_needed(void *opaque)
{
    NV2AState *d = opaque;
    return d->pgraph.renderer &&
           d->pgraph.renderer->type == CONFIG_DISPLAY_RENDERER_METAL4 &&
           d->pgraph.primitive_mode != PRIM_TYPE_INVALID &&
           d->pgraph.metal4_vertex_capture_size != 0;
}
static int vertex_capture_get(QEMUFile *f, void *pv, size_t size,
                              const VMStateField *field)
{
    (void)size;
    (void)field;
    PGRAPHState *pg = pv;
    uint32_t primitive = qemu_get_be32(f);
    uint32_t length = qemu_get_be32(f);
    if (primitive < PRIM_TYPE_POINTS || primitive > PRIM_TYPE_POLYGON ||
        primitive != pg->primitive_mode || !length ||
        length > NV2A_METAL_VERTEX_CAPTURE_MAX)
        return -EINVAL;
    uint8_t *bytes = g_malloc(length);
    if (qemu_get_buffer(f, bytes, length) != length ||
        !pgraph_metal4_validate_vertex_capture(bytes, length)) {
        g_free(bytes);
        return -EINVAL;
    }
    int error = qemu_file_get_error(f);
    if (error) {
        g_free(bytes);
        return error;
    }
    g_free(pg->metal4_vertex_capture);
    pg->metal4_vertex_capture = bytes;
    pg->metal4_vertex_capture_size = length;
    return 0;
}
static int vertex_capture_put(QEMUFile *f, void *pv, size_t size,
                              const VMStateField *field, JSONWriter *vmdesc)
{
    (void)size;
    (void)field;
    (void)vmdesc;
    PGRAPHState *pg = pv;
    if (!pg->metal4_vertex_capture_size ||
        pg->metal4_vertex_capture_size > NV2A_METAL_VERTEX_CAPTURE_MAX ||
        !pgraph_metal4_validate_vertex_capture(pg->metal4_vertex_capture,
                                               pg->metal4_vertex_capture_size))
        return -EINVAL;
    qemu_put_be32(f, pg->primitive_mode);
    qemu_put_be32(f, pg->metal4_vertex_capture_size);
    qemu_put_buffer(f, pg->metal4_vertex_capture,
                    pg->metal4_vertex_capture_size);
    return qemu_file_get_error(f);
}
static const VMStateInfo vertex_capture_info = {
    .name = "native-vertex-capture",
    .get = vertex_capture_get,
    .put = vertex_capture_put,
};
const VMStateDescription vmstate_nv2a_metal4_vertex_capture = {
    .name = "nv2a/metal4-vertex-capture",
    .version_id = 1,
    .minimum_version_id = 1,
    .needed = vertex_capture_needed,
    .fields = (VMStateField[]){ {
                                    .name = "begin-vertex-capture",
                                    .size = sizeof(PGRAPHState),
                                    .info = &vertex_capture_info,
                                    .flags = VMS_SINGLE,
                                    .offset = offsetof(NV2AState, pgraph),
                                },
                                VMSTATE_END_OF_LIST() },
};

static bool begin_capture_needed(void *opaque)
{
    NV2AState *d = opaque;
    return d->pgraph.renderer &&
           d->pgraph.renderer->type == CONFIG_DISPLAY_RENDERER_METAL4 &&
           d->pgraph.primitive_mode != PRIM_TYPE_INVALID &&
           d->pgraph.metal4_begin_capture_size != 0;
}
static int begin_capture_get(QEMUFile *f, void *pv, size_t size,
                             const VMStateField *field)
{
    (void)size;
    (void)field;
    PGRAPHState *pg = pv;
    uint32_t primitive = qemu_get_be32(f);
    uint32_t length = qemu_get_be32(f);
    if (primitive < PRIM_TYPE_POINTS || primitive > PRIM_TYPE_POLYGON ||
        primitive != pg->primitive_mode || !length ||
        length > NV2A_METAL_BEGIN_CAPTURE_MAX)
        return -EINVAL;
    uint8_t *bytes = g_malloc(length);
    if (qemu_get_buffer(f, bytes, length) != length ||
        (!pgraph_metal4_validate_begin_capture(bytes, length) ||
         (uint32_t)ldl_be_p(bytes + 8) != primitive)) {
        g_free(bytes);
        return -EINVAL;
    }
    int error = qemu_file_get_error(f);
    if (error) {
        g_free(bytes);
        return error;
    }
    g_free(pg->metal4_begin_capture);
    pg->metal4_begin_capture = bytes;
    pg->metal4_begin_capture_size = length;
    return 0;
}
static int begin_capture_put(QEMUFile *f, void *pv, size_t size,
                             const VMStateField *field, JSONWriter *vmdesc)
{
    (void)size;
    (void)field;
    (void)vmdesc;
    PGRAPHState *pg = pv;
    if (!pg->metal4_begin_capture_size ||
        pg->metal4_begin_capture_size > NV2A_METAL_BEGIN_CAPTURE_MAX ||
        !pgraph_metal4_validate_begin_capture(pg->metal4_begin_capture,
                                              pg->metal4_begin_capture_size) ||
        (uint32_t)ldl_be_p(pg->metal4_begin_capture + 8) != pg->primitive_mode)
        return -EINVAL;
    qemu_put_be32(f, pg->primitive_mode);
    qemu_put_be32(f, pg->metal4_begin_capture_size);
    qemu_put_buffer(f, pg->metal4_begin_capture, pg->metal4_begin_capture_size);
    return qemu_file_get_error(f);
}
static const VMStateInfo begin_capture_info = {
    .name = "native-begin-capture",
    .get = begin_capture_get,
    .put = begin_capture_put,
};
const VMStateDescription vmstate_nv2a_metal4_begin_capture = {
    .name = "nv2a/metal4-begin-capture",
    .version_id = 1,
    .minimum_version_id = 1,
    .needed = begin_capture_needed,
    .fields = (VMStateField[]){ {
                                    .name = "begin-raster-capture",
                                    .size = sizeof(PGRAPHState),
                                    .info = &begin_capture_info,
                                    .flags = VMS_SINGLE,
                                    .offset = offsetof(NV2AState, pgraph),
                                },
                                VMSTATE_END_OF_LIST() },
};

static bool pending_capture_needed(void *opaque)
{
    NV2AState *d = opaque;
    return d->pgraph.renderer &&
           d->pgraph.renderer->type == CONFIG_DISPLAY_RENDERER_METAL4 &&
           d->pgraph.primitive_mode != PRIM_TYPE_INVALID &&
           d->pgraph.metal4_pending_capture_size != 0;
}
static int pending_capture_get(QEMUFile *f, void *pv, size_t size,
                               const VMStateField *field)
{
    (void)size;
    (void)field;
    PGRAPHState *pg = pv;
    uint32_t primitive = qemu_get_be32(f);
    uint32_t length = qemu_get_be32(f);
    if (primitive < PRIM_TYPE_POINTS || primitive > PRIM_TYPE_POLYGON ||
        primitive != pg->primitive_mode || !length ||
        length > NV2A_METAL_PENDING_CAPTURE_MAX)
        return -EINVAL;
    uint8_t *bytes = g_malloc(length);
    if (qemu_get_buffer(f, bytes, length) != length ||
        (!pgraph_metal4_validate_pending_capture(bytes, length))) {
        g_free(bytes);
        return -EINVAL;
    }
    int error = qemu_file_get_error(f);
    if (error) {
        g_free(bytes);
        return error;
    }
    g_free(pg->metal4_pending_capture);
    pg->metal4_pending_capture = bytes;
    pg->metal4_pending_capture_size = length;
    return 0;
}
static int pending_capture_put(QEMUFile *f, void *pv, size_t size,
                               const VMStateField *field, JSONWriter *vmdesc)
{
    (void)size;
    (void)field;
    (void)vmdesc;
    PGRAPHState *pg = pv;
    if (!pg->metal4_pending_capture_size ||
        pg->metal4_pending_capture_size > NV2A_METAL_PENDING_CAPTURE_MAX ||
        !pgraph_metal4_validate_pending_capture(
            pg->metal4_pending_capture, pg->metal4_pending_capture_size))
        return -EINVAL;
    qemu_put_be32(f, pg->primitive_mode);
    qemu_put_be32(f, pg->metal4_pending_capture_size);
    qemu_put_buffer(f, pg->metal4_pending_capture,
                    pg->metal4_pending_capture_size);
    return qemu_file_get_error(f);
}
static const VMStateInfo pending_capture_info = {
    .name = "native-pending-capture",
    .get = pending_capture_get,
    .put = pending_capture_put,
};
const VMStateDescription vmstate_nv2a_metal4_pending_capture = {
    .name = "nv2a/metal4-pending-capture",
    .version_id = 1,
    .minimum_version_id = 1,
    .needed = pending_capture_needed,
    .fields = (VMStateField[]){ {
                                    .name = "pending-transformed-capture",
                                    .size = sizeof(PGRAPHState),
                                    .info = &pending_capture_info,
                                    .flags = VMS_SINGLE,
                                    .offset = offsetof(NV2AState, pgraph),
                                },
                                VMSTATE_END_OF_LIST() },
};
