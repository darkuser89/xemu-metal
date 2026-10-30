
testblock = declare_dependency(dependencies: [block], sources: 'iothread.c')

if is_variable('nv2a_metal4')
  test('test-xemu-metal-macos-libraries', python,
    args: files('test-download-macos-libs.py'),
    env: ['PYTHONDONTWRITEBYTECODE=1'],
    suite: ['unit', 'thorough'], timeout: 30)
  foreach metal4_test : ['command', 'shader-library', 'display', 'geometry', 'lines', 'polygons', 'two-sided', 'point-sprite', 'logic', 'dither', 'vertex-program', 'vertex-state', 'vertex-state-range', 'pending-archive', 'archive-native', 'vertex-writable', 'vertex-output-address', 'vertex-fog-mask', 'vertex-fixed', 'vertex-fetch', 'pixel-combiner', 'pixel-shader', 'visibility', 'texture-upload', 'texture-snapshot', 'surface-transfer', 'surface-cache', 'clear', 'texture-cache', 'blit', 'scanout', 'vga']
    metal4_test_name = 'test-nv2a-metal-' + metal4_test
    metal4_test_sources = [metal4_test_name + '.m']
    if metal4_test == 'pixel-shader'
      metal4_test_sources += [metal4_pixel_source]
    endif
    metal4_test_exe = executable(metal4_test_name, metal4_test_sources,
      include_directories: include_directories('../..'),
      objc_args: metal4_objc_args,
      link_args: ['-mmacosx-version-min=26.0'],
      dependencies: metal4_frameworks,
      link_with: nv2a_metal4,
    )
    test(metal4_test_name, metal4_test_exe,
      suite: metal4_test == 'command' ? ['unit'] : ['unit', 'thorough'],
      timeout: 120,
    )
    if metal4_test == 'surface-cache'
      test('test-nv2a-metal-CPU-GPU-wait', metal4_test_exe,
        args: ['--CPU-GPU-wait'], suite: ['unit', 'thorough'], timeout: 120)
    endif
  endforeach
endif

if is_variable('nv2a_metal4') and is_variable('xemu_metal4_imgui')
  metal4_imgui_test = executable('test-xemu-metal-imgui', 'test-xemu-metal-imgui.mm',
    include_directories: include_directories('../..'),
    objcpp_args: metal4_imgui_args,
    link_args: ['-mmacosx-version-min=26.0'],
    dependencies: [metal4_imgui_frameworks, imgui],
    link_with: [nv2a_metal4, xemu_metal4_imgui],
  )
  test('test-xemu-metal-imgui', metal4_imgui_test, suite: ['unit', 'thorough'], timeout: 120)
endif

if is_variable('xemu_metal4_window')
  metal4_window_test = executable('test-xemu-metal-window', 'test-xemu-metal-window.m',
    include_directories: include_directories('../..'),
    objc_args: ['-fobjc-arc', '-fblocks', '-mmacosx-version-min=26.0'],
    link_args: ['-mmacosx-version-min=26.0'],
    dependencies: [metal4_window_frameworks, metal4_window_sdl_headers],
    link_with: xemu_metal4_window,
  )
  test('test-xemu-metal-window', metal4_window_test, suite: ['unit'])
endif

if is_variable('nv2a_metal4') and is_variable('xemu_metal4_decals')
  metal4_decal_test = executable('test-xemu-metal-decal', 'test-xemu-metal-decal.m',
    include_directories: include_directories('../..'),
    objc_args: ['-fobjc-arc', '-fblocks', '-mmacosx-version-min=26.0'],
    link_args: ['-mmacosx-version-min=26.0'],
    dependencies: metal4_window_frameworks,
    link_with: [nv2a_metal4, xemu_metal4_decals],
  )
  test('test-xemu-metal-decal', metal4_decal_test, suite: ['unit', 'thorough'], timeout: 120)
endif

if is_variable('nv2a_metal4') and is_variable('xemu_metal4_frame_images')
  metal4_images_test = executable('test-xemu-metal-frame-images',
    'test-xemu-metal-frame-images.mm',
    include_directories: include_directories('../..'),
    objcpp_args: metal4_imgui_args + ['-Wall', '-Wextra', '-Werror'],
    link_args: ['-mmacosx-version-min=26.0'],
    dependencies: [metal4_imgui_frameworks, fpng],
    link_with: [nv2a_metal4, xemu_metal4_frame_images],
  )
  test('test-xemu-metal-frame-images', metal4_images_test,
    suite: ['unit', 'thorough'], timeout: 120)
endif

if is_variable('nv2a_metal4_qemu')
  metal4_save_lifecycle_test = executable('test-nv2a-metal-save-lifecycle',
    'test-nv2a-metal-save-lifecycle.c',
    include_directories: metal4_qemu_includes,
    c_args: metal4_qemu_c_args + ['-Wall', '-Wextra', '-Werror'],
    link_args: ['-mmacosx-version-min=26.0'],
    dependencies: [glib, qemuutil, migration, io],
    link_with: nv2a_metal4_qemu,
  )
  test('test-nv2a-metal-save-lifecycle', metal4_save_lifecycle_test,
    suite: ['unit', 'thorough'], timeout: 60)
  metal4_rendering_test = executable('test-xemu-metal-rendering',
    'test-xemu-metal-rendering.mm',
    '../../ui/xemu-thumbnail.cc',
    '../../ui/xui/gl-helpers.cc',
    include_directories: metal4_qemu_includes,
    objcpp_args: metal4_imgui_args + ['-Wall', '-Wextra', '-Werror'],
    cpp_args: ['-std=c++17', '-Wall', '-Wextra', '-Werror'],
    link_args: ['-mmacosx-version-min=26.0'],
    dependencies: [metal4_window_frameworks, imgui, implot, genconfig, stb_image, fpng, glib, qemuutil, sdl, opengl],
    link_with: [nv2a_metal4, xemu_metal4_rendering, libpfile],
  )
  test('test-xemu-metal-rendering', metal4_rendering_test,
    suite: ['unit', 'thorough'], timeout: 120)
  metal4_frontend_test = executable('test-xemu-metal-frontend',
    'test-xemu-metal-frontend.mm',
    include_directories: include_directories('../..'),
    objcpp_args: metal4_imgui_args + ['-Wall', '-Wextra', '-Werror'],
    link_args: ['-mmacosx-version-min=26.0'],
    dependencies: [metal4_window_frameworks, imgui, xemu_metal4_frontend_dep],
    link_with: nv2a_metal4,
  )
  test('test-xemu-metal-frontend', metal4_frontend_test,
    suite: ['unit', 'thorough'], timeout: 120)
  metal4_state_pgraph_test = executable('test-nv2a-metal-state-pgraph',
    'test-nv2a-metal-state-pgraph.m',
    include_directories: metal4_qemu_includes,
    objc_args: metal4_qemu_args,
    link_args: ['-mmacosx-version-min=26.0'],
    dependencies: [glib, metal4_frameworks],
    link_with: [nv2a_metal4_qemu, nv2a_metal4],
  )
  test('test-nv2a-metal-state-pgraph', metal4_state_pgraph_test,
    suite: ['unit', 'thorough'], timeout: 240)
  metal4_pgraph_test = executable('test-nv2a-metal-surface-pgraph',
    'test-nv2a-metal-surface-pgraph.m',
    include_directories: metal4_qemu_includes,
    objc_args: metal4_qemu_args,
    link_args: ['-mmacosx-version-min=26.0'],
    dependencies: [metal4_frameworks, glib, qemuutil],
    link_with: [nv2a_metal4_qemu, nv2a_metal4],
  )
  test('test-nv2a-metal-surface-pgraph', metal4_pgraph_test,
    suite: ['unit', 'thorough'], timeout: 120)
  metal4_texture_pgraph_test = executable('test-nv2a-metal-texture-pgraph',
    'test-nv2a-metal-texture-pgraph.m',
    '../../hw/xbox/nv2a/pgraph/texture.c',
    include_directories: metal4_qemu_includes,
    objc_args: metal4_qemu_args,
    c_args: metal4_qemu_c_args,
    link_args: ['-mmacosx-version-min=26.0'],
    dependencies: [metal4_frameworks, glib, qemuutil],
    link_with: [nv2a_metal4_qemu, nv2a_metal4],
  )
  test('test-nv2a-metal-texture-pgraph', metal4_texture_pgraph_test,
    suite: ['unit', 'thorough'], timeout: 120)
  test('test-nv2a-metal-hilo16-border', metal4_texture_pgraph_test,
    args: ['--hilo16-border'], suite: ['unit', 'thorough'], timeout: 120)
  test('test-nv2a-metal-signed-hilo16', metal4_texture_pgraph_test,
    args: ['--signed-hilo16'], suite: ['unit', 'thorough'], timeout: 120)
  test('test-nv2a-metal-signed-hilo16-volume', metal4_texture_pgraph_test,
    args: ['--signed-hilo16-volume'], suite: ['unit', 'thorough'], timeout: 120)
  test('test-nv2a-metal-signed-hilo16-border', metal4_texture_pgraph_test,
    args: ['--signed-hilo16-border'], suite: ['unit', 'thorough'], timeout: 180)
  test('test-nv2a-metal-signed-hilo16-cube-border', metal4_texture_pgraph_test,
    args: ['--signed-hilo16-cube-border'], suite: ['unit', 'thorough'], timeout: 120)
  test('test-nv2a-metal-signed-hilo16-convolution', metal4_texture_pgraph_test,
    args: ['--signed-hilo16-convolution'], suite: ['unit', 'thorough'], timeout: 120)
  test('test-nv2a-metal-hilo16-gradients', metal4_texture_pgraph_test,
    args: ['--hilo16-gradients'], suite: ['unit', 'thorough'], timeout: 180)
  test('test-nv2a-metal-hilo16-rectangle-gradients', metal4_texture_pgraph_test,
    args: ['--hilo16-rectangle-gradients'], suite: ['unit', 'thorough'], timeout: 180)
  test('test-nv2a-metal-hilo16-projective-gradients', metal4_texture_pgraph_test,
    args: ['--hilo16-projective-gradients'], suite: ['unit', 'thorough'], timeout: 180)
  test('test-nv2a-metal-hilo16-scaled-gradients', metal4_texture_pgraph_test,
    args: ['--hilo16-scaled-gradients'], suite: ['unit', 'thorough'], timeout: 300)
  test('test-nv2a-metal-hilo16-convolution', metal4_texture_pgraph_test,
    args: ['--hilo16-convolution'], suite: ['unit', 'thorough'], timeout: 120)
  test('test-nv2a-metal-cube-border', metal4_texture_pgraph_test,
    args: ['--cube-border'], suite: ['unit', 'thorough'], timeout: 120)
  metal4_pixel_pgraph_test = executable('test-nv2a-metal-pixel-pgraph',
    'test-nv2a-metal-pixel-pgraph.m',
    '../../hw/xbox/nv2a/pgraph/texture.c',
    include_directories: metal4_qemu_includes,
    objc_args: metal4_qemu_args,
    c_args: metal4_qemu_c_args,
    link_args: ['-mmacosx-version-min=26.0'],
    dependencies: [metal4_frameworks, glib, qemuutil],
    link_with: [nv2a_metal4_qemu, nv2a_metal4],
  )
  test('test-nv2a-metal-pixel-pgraph', metal4_pixel_pgraph_test,
    suite: ['unit', 'thorough'], timeout: 120)
  foreach metal4_epoch_test : ['vertex-capture', 'vertex-constant-epoch', 'vertex-epoch',
                              'input-checkpoint', 'pending-journal', 'pending-pgraph',
                              'pending-native']
    metal4_epoch_name = 'test-nv2a-metal-' + metal4_epoch_test
    metal4_epoch_exe = executable(metal4_epoch_name,
      metal4_epoch_name + '.m',
      include_directories: metal4_qemu_includes,
      objc_args: metal4_qemu_args,
      link_args: ['-mmacosx-version-min=26.0'],
      dependencies: [metal4_frameworks, glib, qemuutil],
      link_with: [nv2a_metal4_qemu, nv2a_metal4],
    )
    test(metal4_epoch_name, metal4_epoch_exe,
      suite: ['unit', 'thorough'], timeout: 120)
  endforeach
  metal4_vertex_pgraph_test = executable('test-nv2a-metal-vertex-pgraph',
    'test-nv2a-metal-vertex-pgraph.m',
    include_directories: metal4_qemu_includes,
    objc_args: metal4_qemu_args,
    link_args: ['-mmacosx-version-min=26.0'],
    dependencies: [metal4_frameworks, glib, qemuutil],
    link_with: [nv2a_metal4_qemu, nv2a_metal4],
  )
  test('test-nv2a-metal-vertex-pgraph', metal4_vertex_pgraph_test,
    suite: ['unit', 'thorough'], timeout: 120)
  metal4_fetch_pgraph_test = executable('test-nv2a-metal-fetch-pgraph',
    'test-nv2a-metal-fetch-pgraph.m',
    include_directories: metal4_qemu_includes,
    objc_args: metal4_qemu_args,
    link_args: ['-mmacosx-version-min=26.0'],
    dependencies: [metal4_frameworks, glib, qemuutil],
    link_with: [nv2a_metal4_qemu, nv2a_metal4],
  )
  test('test-nv2a-metal-fetch-pgraph', metal4_fetch_pgraph_test,
    suite: ['unit', 'thorough'], timeout: 120)
  metal4_draw_pgraph_test = executable('test-nv2a-metal-draw-pgraph',
    'test-nv2a-metal-draw-pgraph.m',
    '../../hw/xbox/nv2a/pgraph/texture.c',
    include_directories: metal4_qemu_includes,
    objc_args: metal4_qemu_args,
    c_args: metal4_qemu_c_args,
    link_args: ['-mmacosx-version-min=26.0'],
    dependencies: [metal4_frameworks, glib, qemuutil],
    link_with: [nv2a_metal4_qemu, nv2a_metal4],
  )
  test('test-nv2a-metal-draw-pgraph', metal4_draw_pgraph_test,
    suite: ['unit', 'thorough'], timeout: 120)
  foreach cache_test : ['concurrent-XF-RAM', 'cache-register-isolation', 'cache-transaction']
    test('test-nv2a-metal-' + cache_test, metal4_draw_pgraph_test,
      args: ['--' + cache_test], suite: ['unit', 'thorough'], timeout: 120)
  endforeach
  metal4_renderer_test = executable('test-nv2a-metal-renderer',
    'test-nv2a-metal-renderer.m',
    '../../hw/xbox/nv2a/pgraph/pgraph.c',
    '../../hw/xbox/nv2a/pgraph/vertex.c',
    '../../hw/xbox/nv2a/pgraph/texture.c',
    '../../hw/xbox/nv2a/pgraph/glsl/vsh.c',
    '../../hw/xbox/nv2a/pgraph/glsl/vsh-ff.c',
    '../../hw/xbox/nv2a/pgraph/glsl/vsh-prog.c',
    '../../hw/xbox/nv2a/pgraph/glsl/common.c',
    include_directories: metal4_qemu_includes,
    objc_args: metal4_qemu_args,
    c_args: metal4_qemu_c_args,
    link_args: ['-mmacosx-version-min=26.0'],
    dependencies: [metal4_frameworks, glib, qemuutil, nv2a_vsh_cpu, fpng, migration, io],
    link_with: [nv2a_metal4_qemu, nv2a_metal4, xemu_metal4_frame_images],
  )
  test('test-nv2a-metal-renderer', metal4_renderer_test,
    suite: ['unit', 'thorough'], timeout: 3600)
  test('test-nv2a-metal-w-prefix-rotations', metal4_renderer_test,
    args: ['--w-prefix-rotations'], suite: ['unit', 'thorough'], timeout: 1800, is_parallel: false)
  test('test-nv2a-metal-array-current-restore', metal4_renderer_test,
    args: ['--array-current-restore'], suite: ['unit', 'thorough'], timeout: 600)
  test('test-nv2a-metal-xf-between-draws', metal4_renderer_test,
    args: ['--xf-between-draws'], suite: ['unit', 'thorough'], timeout: 240)
  test('test-nv2a-metal-xf-upload-restore', metal4_renderer_test,
    args: ['--xf-upload-restore'], suite: ['unit', 'thorough'], timeout: 300, is_parallel: false)
  test('test-nv2a-metal-blit-coherence', metal4_renderer_test,
    args: ['--blit-coherence'], suite: ['unit', 'thorough'], timeout: 120)
  test('test-nv2a-metal-state-boundaries', metal4_renderer_test,
    args: ['--state-boundaries'], suite: ['unit', 'thorough'], timeout: 240)
  test('test-nv2a-metal-idx-normalization', metal4_renderer_test,
    args: ['--idx-normalization'], suite: ['unit', 'thorough'], timeout: 120, is_parallel: false)
  test('test-nv2a-metal-cube-af-begin', metal4_renderer_test,
    args: ['--hilo16-cube-af-begin'], suite: ['unit', 'thorough'], timeout: 900, is_parallel: false)
  test('test-nv2a-metal-cube-dot-begin', metal4_renderer_test,
    args: ['--hilo16-cube-dot-begin'], suite: ['unit', 'thorough'], timeout: 900, is_parallel: false)
  test('test-nv2a-metal-cube-lookup-begin', metal4_renderer_test,
    args: ['--hilo16-cube-lookup-begin'], suite: ['unit', 'thorough'], timeout: 900, is_parallel: false)
  test('test-nv2a-metal-cube-brdf-begin', metal4_renderer_test,
    args: ['--hilo16-cube-brdf-begin'], suite: ['unit', 'thorough'], timeout: 1200, is_parallel: false)
  test('test-nv2a-metal-volume-brdf-begin', metal4_renderer_test,
    args: ['--hilo16-volume-brdf-begin'], suite: ['unit', 'thorough'], timeout: 1200, is_parallel: false)

endif

tests = {
  'check-block-qdict': [],
  'check-qdict': [],
  'check-qnum': [],
  'check-qstring': [],
  'check-qlist': [],
  'check-qnull': [],
  'check-qobject': [],
  'check-qjson': [],
  'check-qlit': [],
  'test-error-report': [],
  'test-qobject-output-visitor': [testqapi],
  'test-clone-visitor': [testqapi],
  'test-qobject-input-visitor': [testqapi],
  'test-forward-visitor': [testqapi],
  'test-string-input-visitor': [testqapi],
  'test-string-output-visitor': [testqapi],
  'test-visitor-serialization': [testqapi],
  'test-bitmap': [],
  'test-resv-mem': [],
  # all code tested by test-x86-topo is inside topology.h
  'test-x86-topo': [],
  'test-cutils': [],
  'test-div128': [],
  'test-shift128': [],
  'test-mul64': [],
  # all code tested by test-int128 is inside int128.h
  'test-int128': [],
  'rcutorture': [],
  'test-rcu-list': [],
  'test-rcu-simpleq': [],
  'test-rcu-tailq': [],
  'test-rcu-slist': [],
  'test-qdist': [],
  'test-qht': [],
  'test-qtree': [],
  'test-bitops': [],
  'test-bitcnt': [],
  'test-qgraph': ['../qtest/libqos/qgraph.c'],
  'check-qom-interface': [qom],
  'check-qom-proplist': [qom],
  'test-qemu-opts': [],
  'test-keyval': [testqapi],
  'test-logging': [],
  'test-qapi-util': [],
  'test-interval-tree': [],
  'test-fifo': [],
}

if have_system or have_tools
  tests += {
    'test-qmp-event': [testqapi],
  }

  if seccomp.found()
    tests += {'test-seccomp': ['../../system/qemu-seccomp.c', seccomp]}
  endif
endif

if have_block
  tests += {
    'test-coroutine': [testblock],
    'test-aio': [testblock],
    'test-aio-multithread': [testblock],
    'test-throttle': [testblock],
    'test-thread-pool': [testblock],
    'test-hbitmap': [testblock],
    'test-bdrv-drain': [testblock],
    'test-bdrv-graph-mod': [testblock],
    'test-blockjob': [testblock],
    'test-blockjob-txn': [testblock],
    'test-block-backend': [testblock],
    'test-block-iothread': [testblock],
    'test-write-threshold': [testblock],
    'test-crypto-hash': [crypto],
    'test-crypto-hmac': [crypto],
    'test-crypto-cipher': [crypto],
    'test-crypto-akcipher': [crypto],
    'test-crypto-secret': [crypto, keyutils],
    'test-crypto-der': [crypto],
    'test-authz-simple': [authz],
    'test-authz-list': [authz],
    'test-authz-listfile': [authz],
    'test-io-task': [testblock],
    'test-io-channel-socket': ['socket-helpers.c', 'io-channel-helpers.c', io],
    'test-io-channel-file': ['io-channel-helpers.c', io],
    'test-io-channel-command': ['io-channel-helpers.c', io],
    'test-io-channel-buffer': ['io-channel-helpers.c', io],
    'test-io-channel-null': [io],
    'test-crypto-ivgen': [io],
    'test-crypto-afsplit': [io],
    'test-crypto-block': [io],
    'test-timed-average': [],
    'test-uuid': [],
  }
  if gnutls.found() and \
     tasn1.found() and \
     host_os != 'windows'
    tests += {
      'test-crypto-tlscredsx509': ['crypto-tls-x509-helpers.c',
                                   tasn1, crypto, gnutls],
      'test-crypto-tlssession': ['crypto-tls-x509-helpers.c', 'crypto-tls-psk-helpers.c',
                                 tasn1, crypto, gnutls],
      'test-io-channel-tls': ['io-channel-helpers.c', 'crypto-tls-x509-helpers.c',
                              tasn1, io, crypto, gnutls]}
  endif
  if pam.found()
    tests += {'test-authz-pam': [authz]}
  endif
  if host_os != 'windows'
    tests += {
      'test-image-locking': [testblock],
      'test-nested-aio-poll': [],
    }
  endif
  if config_host_data.get('CONFIG_REPLICATION')
    tests += {'test-replication': [testblock]}
  endif
  tests += {'test-crypto-pbkdf': [io]}
endif

if have_system
  tests += {
    'ptimer-test': ['ptimer-test-stubs.c', meson.project_source_root() / 'hw/core/ptimer.c'],
    'test-iov': [],
    'test-opts-visitor': [testqapi],
    'test-xs-node': [qom],
    'test-virtio-dmabuf': [meson.project_source_root() / 'hw/display/virtio-dmabuf.c'],
    'test-qmp-cmds': [testqapi],
    'test-xbzrle': [migration],
    'test-util-sockets': ['socket-helpers.c'],
    'test-base64': [],
    'test-bufferiszero': [],
    'test-smp-parse': [qom, meson.project_source_root() / 'hw/core/machine-smp.c'],
    'test-vmstate': [migration, io],
    'test-yank': ['socket-helpers.c', qom, io, chardev]
  }
  if config_host_data.get('CONFIG_INOTIFY1')
    tests += {'test-util-filemonitor': []}
  endif

  # Some tests: test-char, test-qdev-global-props, and test-qga,
  # are not runnable under TSan due to a known issue.
  # https://github.com/google/sanitizers/issues/1116
  if not get_option('tsan')
    if host_os != 'windows'
        tests += {
          'test-char': ['socket-helpers.c', qom, io, chardev]
        }
    endif

    tests += {
      'test-qdev-global-props': [qom, hwcore]
    }
  endif
endif

if have_ga and host_os == 'linux'
  tests += {'test-qga': ['../qtest/libqmp.c']}
  test_deps += {'test-qga': qga}
endif

test_env = environment()
test_env.set('G_TEST_SRCDIR', meson.current_source_dir())
test_env.set('G_TEST_BUILDDIR', meson.current_build_dir())

slow_tests = {
  'test-aio-multithread' : 120,
  'test-bufferiszero': 60,
  'test-crypto-block' : 300,
  'test-crypto-tlscredsx509': 90,
  'test-crypto-tlssession': 90,
  'test-replication': 60,
}

foreach test_name, extra: tests
  src = [test_name + '.c']
  deps = [qemuutil]
  if extra.length() > 0
    # use a sourceset to quickly separate sources and deps
    test_ss = ss.source_set()
    test_ss.add(extra)
    src += test_ss.all_sources()
    deps += test_ss.all_dependencies()
  endif
  exe = executable(test_name, src, genh, dependencies: deps)

  test(test_name, exe,
       depends: test_deps.get(test_name, []),
       env: test_env,
       args: ['--tap', '-k'],
       protocol: 'tap',
       timeout: slow_tests.get(test_name, 30),
       priority: slow_tests.get(test_name, 30),
       suite: ['unit'])
endforeach
