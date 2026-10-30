metal4_frameworks = dependency('appleframeworks', modules: ['Foundation', 'Metal', 'QuartzCore'])
metal4_objc_args = ['-fobjc-arc', '-fblocks', '-mmacosx-version-min=26.0']

metal4_display_source = custom_target('nv2a-metal4-display-source',
    input: files('display-uniforms.h', 'display.metal'),
    output: 'display-source.h',
    command: [python, files('shader-source.py'), '@INPUT@'],
    capture: true,
)

metal4_geometry_source = custom_target('nv2a-metal4-geometry-source',
    input: files('geometry-types.h', 'geometry-math.metal', 'polygon-coverage.metal', 'geometry.metal'),
    output: 'geometry-source.h',
    command: [python, files('shader-source.py'), '@INPUT@'],
    capture: true,
)

metal4_program_source = custom_target('nv2a-metal4-vertex-program-source',
    input: files('vertex-program-types.h', 'geometry-types.h', 'vertex-common.metal',
                 'vertex-program.metal'),
    output: 'vertex-program-source.h',
    command: [python, files('shader-source.py'), '@INPUT@'],
    capture: true,
)

metal4_context_source = custom_target('nv2a-metal4-vertex-context-source',
    input: files('vertex-program-types.h', 'geometry-types.h', 'vertex-context-types.h',
                 'vertex-common.metal', 'vertex-program.metal', 'vertex-context.metal'),
    output: 'vertex-context-source.h',
    command: [python, files('shader-source.py'), '@INPUT@'],
    capture: true,
)

metal4_fixed_source = custom_target('nv2a-metal4-vertex-fixed-source',
    input: files('../../nv2a_regs.h', 'vertex-program-types.h', 'geometry-types.h',
                 'vertex-fixed-types.h', 'vertex-common.metal', 'vertex-fixed.metal'),
    output: 'vertex-fixed-source.h',
    command: [python, files('shader-source.py'), '@INPUT@'],
    capture: true,
)

metal4_fetch_source = custom_target('nv2a-metal4-vertex-fetch-source',
    input: files('../../nv2a_regs.h', 'vertex-program-types.h',
                 'vertex-fetch-types.h', 'vertex-normalize.h', 'vertex-fetch.metal'),
    output: 'vertex-fetch-source.h',
    command: [python, files('shader-source.py'), '@INPUT@'],
    capture: true,
)

metal4_combiner_source = custom_target('nv2a-metal4-pixel-combiner-source',
    input: files('../psh_regs.h', 'pixel-combiner-types.h', 'pixel-combiner.metal'),
    output: 'pixel-combiner-source.h',
    command: [python, files('shader-source.py'), '@INPUT@'],
    capture: true,
)

metal4_pixel_source = custom_target('nv2a-metal4-pixel-shader-source',
    input: files('../../nv2a_regs.h', '../psh_regs.h', 'pixel-combiner-types.h', 'texture-sampler-types.h', 'pixel-shader-types.h',
                 'geometry-types.h', 'geometry-math.metal', 'polygon-coverage.metal', 'color-quantize.metal', 'pixel-specialization.metal', 'pixel-combiner.metal', 'texture-sample.metal', 'pixel-shader.metal'),
    output: 'pixel-shader-source.h',
    command: [python, files('shader-source.py'), '@INPUT@'],
    capture: true,
)

metal4_texture_source = custom_target('nv2a-metal4-texture-upload-source',
    input: files('../../nv2a_regs.h', 'texture-upload-types.h', 'texture-upload.metal'),
    output: 'texture-upload-source.h',
    command: [python, files('shader-source.py'), '@INPUT@'],
    capture: true,
)

metal4_surface_source = custom_target('nv2a-metal4-surface-transfer-source',
    input: files('surface-transfer-types.h', 'surface-transfer.metal'),
    output: 'surface-transfer-source.h',
    command: [python, files('shader-source.py'), '@INPUT@'],
    capture: true,
)

metal4_clear_source = custom_target('nv2a-metal4-clear-source',
    input: files('clear-types.h', 'color-quantize.metal', 'clear.metal'),
    output: 'clear-source.h',
    command: [python, files('shader-source.py'), '@INPUT@'],
    capture: true,
)

metal4_texture_cache_source = custom_target('nv2a-metal4-texture-cache-source',
    input: files('texture-cache-types.h', 'texture-cache.metal'),
    output: 'texture-cache-source.h',
    command: [python, files('shader-source.py'), '@INPUT@'],
    capture: true,
)

metal4_blit_source = custom_target('nv2a-metal4-blit-source',
    input: files('../../nv2a_regs.h', 'blit-types.h', 'blit.metal'),
    output: 'blit-source.h',
    command: [python, files('shader-source.py'), '@INPUT@'],
    capture: true,
)

metal4_scanout_source = custom_target('nv2a-metal4-scanout-source',
    input: files('scanout-types.h', 'color-quantize.metal', 'scanout.metal'),
    output: 'scanout-source.h',
    command: [python, files('shader-source.py'), '@INPUT@'],
    capture: true,
)

metal4_vga_source = custom_target('nv2a-metal4-vga-source',
    input: files('vga-types.h', 'vga.metal'),
    output: 'vga-source.h',
    command: [python, files('shader-source.py'), '@INPUT@'],
    capture: true,
)

# Build the native components independently until the PGRAPH callbacks and
# window integration are complete. Do not select an incomplete renderer.
nv2a_metal4 = static_library('nv2a-metal4',
    sources: [files('command.m', 'lru-cache.m', 'shader-library.m', 'display.m', 'geometry.m', 'vertex-program.m', 'vertex-state.m', 'vertex-writable.m', 'vertex-epoch.m', 'pending-journal.m', 'pending-archive.m', 'archive-native.m', 'pending-native.m', 'vertex-stream.m', 'vertex-fixed.m', 'vertex-fetch.m', 'pixel-combiner.m', 'pixel-shader.m', 'texture-upload.m', 'texture-sampler.m', 'texture-snapshot.m', 'texture-snapshot-pgraph.m', 'draw-state.m', 'surface-transfer.m', 'surface-cache.m', 'clear.m', 'texture-cache.m', 'blit.m', 'scanout.m', 'vga.m'),
              metal4_display_source, metal4_geometry_source, metal4_program_source, metal4_context_source,
              metal4_fixed_source, metal4_fetch_source, metal4_combiner_source, metal4_pixel_source, metal4_texture_source, metal4_surface_source, metal4_clear_source, metal4_texture_cache_source, metal4_blit_source, metal4_scanout_source, metal4_vga_source],
    objc_args: metal4_objc_args,
    dependencies: metal4_frameworks,
)
