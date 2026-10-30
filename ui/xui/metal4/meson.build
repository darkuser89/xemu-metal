metal4_imgui_frameworks = dependency('appleframeworks', modules: ['Foundation', 'Metal'])
metal4_imgui_args = ['-std=c++17', '-fobjc-arc', '-fblocks', '-mmacosx-version-min=26.0']
metal4_imgui_source = custom_target('xemu-metal4-imgui-source',
    input: 'imgui.metal',
    output: 'imgui-source.h',
    command: [python, files('../../../hw/xbox/nv2a/pgraph/metal/shader-source.py'), '@INPUT@'],
    capture: true,
)

# The window/UI integration selects this backend after all GL textures and
# custom UI drawing paths have been replaced.
xemu_metal4_imgui = static_library('xemu-metal4-imgui',
    sources: [files('imgui-renderer.mm'), metal4_imgui_source],
    include_directories: include_directories('../../..'),
    objcpp_args: metal4_imgui_args,
    dependencies: [metal4_imgui_frameworks, imgui],
)

metal4_window_frameworks = dependency('appleframeworks',
    modules: ['Foundation', 'Metal', 'QuartzCore', 'CoreGraphics'])
metal4_window_sdl_headers = sdl.partial_dependency(compile_args: true, includes: true)
xemu_metal4_window = static_library('xemu-metal4-window',
    sources: files('window.m'),
    include_directories: include_directories('../../..'),
    objc_args: ['-fobjc-arc', '-fblocks', '-mmacosx-version-min=26.0'],
    dependencies: [metal4_window_frameworks, metal4_window_sdl_headers],
)
xemu_metal4_window_dep = declare_dependency(link_with: xemu_metal4_window,
    dependencies: [metal4_window_frameworks, sdl])

metal4_decal_source = custom_target('xemu-metal4-decal-source',
    input: files('decal-uniforms.h', 'decal.metal'),
    output: 'decal-source.h',
    command: [python, files('../../../hw/xbox/nv2a/pgraph/metal/shader-source.py'), '@INPUT@'],
    capture: true,
)
xemu_metal4_decals = static_library('xemu-metal4-decals',
    sources: [files('decal.m'), metal4_decal_source],
    include_directories: include_directories('../../..'),
    objc_args: ['-fobjc-arc', '-fblocks', '-mmacosx-version-min=26.0'],
    dependencies: metal4_window_frameworks,
)

metal4_frame_images_source = custom_target('xemu-metal4-frame-images-source',
    input: 'frame-images.metal',
    output: 'frame-images-source.h',
    command: [python, files('../../../hw/xbox/nv2a/pgraph/metal/shader-source.py'), '@INPUT@'],
    capture: true,
)
xemu_metal4_frame_images = static_library('xemu-metal4-frame-images',
    sources: [files('frame-images.mm'), metal4_frame_images_source],
    include_directories: include_directories('../../..'),
    objcpp_args: metal4_imgui_args,
    dependencies: [metal4_imgui_frameworks, fpng],
)
xemu_ss.add(declare_dependency(link_with: xemu_metal4_frame_images,
    dependencies: metal4_imgui_frameworks))

xemu_metal4_frontend = static_library('xemu-metal4-frontend',
    sources: files('frontend.mm'),
    include_directories: include_directories('../../..'),
    objcpp_args: metal4_imgui_args + ['-Wall', '-Wextra', '-Werror'],
    dependencies: [metal4_window_frameworks, imgui, sdl],
    link_with: [xemu_metal4_imgui, xemu_metal4_window, xemu_metal4_decals],
)
xemu_metal4_frontend_dep = declare_dependency(link_with: xemu_metal4_frontend,
    dependencies: [metal4_window_frameworks, sdl])
xemu_ss.add(xemu_metal4_frontend_dep)

xemu_metal4_rendering = static_library('xemu-metal4-rendering',
    sources: files('rendering.cc') + genh,
    include_directories: include_directories('../../..', '../../../include',
        is_system: true),
    cpp_args: ['-std=c++17', '-Wall', '-Wextra', '-Werror', '-mmacosx-version-min=26.0'],
    dependencies: [glib, genconfig, stb_image, xemu_metal4_frontend_dep],
    link_with: xemu_metal4_frame_images,
)
