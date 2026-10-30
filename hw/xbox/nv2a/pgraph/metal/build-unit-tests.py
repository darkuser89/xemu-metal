#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.0-or-later
"""Build isolated native Metal tests without configuring or starting xemu.

Uses real QEMU/NV2A headers and repository generators with a minimal i386
system-test configuration. These tests supply their existing VM/DMA mocks;
this is not a production emulator build. Requires pkg-config/GLib, PyYAML,
and the repository-pinned genconfig under BUILD/deps/genconfig. The renderer
target also requires nv2a_vsh_cpu under BUILD/deps/nv2a_vsh_cpu at the revision
pinned by the repository. All generated files, dependencies, objects and
executables stay in the separate build tree.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--target", choices=("texture-pgraph", "texture-cache",
                                                 "visibility", "pixel-shader", "draw-pgraph", "renderer", "pending-journal", "pending-pgraph", "shader-library",
                                                 "texture-snapshot",
                                                 "texture-upload", "vertex-fetch", "fetch-pgraph", "vertex-epoch", "vertex-writable", "vertex-state", "vertex-fixed", "vertex-capture", "vertex-constant-epoch", "pixel-pgraph",
                                                 "command", "clear", "blit", "transfer-uniforms", "pending-native", "pending-archive", "archive-native", "vertex-slices", "surface-cache", "surface-transfer",
                                                 "scanout", "display", "scanout-hazards", "vga", "ui-decal", "ui-imgui", "ui-hazards", "ui-frame-images",
                                                 "geometry", "lines", "polygons", "direct-points", "direct-lines", "direct-triangles"),
                        action="append")
    args = parser.parse_args()
    ui_targets = {"ui-decal", "ui-imgui", "ui-hazards", "ui-frame-images"}
    selected = set(args.target or [])
    root = Path(__file__).resolve().parents[5]
    metal = root / "hw/xbox/nv2a/pgraph/metal"
    build = args.build_dir.resolve()
    if (build.is_relative_to(root) or root.is_relative_to(build) or
            any("audit" in part.lower() for part in build.parts)):
        parser.error("Build directory must be outside project code and audit")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("Native Metal tests require Apple Silicon macOS")
    deployment = platform.mac_ver()[0]
    if int(deployment.split(".")[0]) < 26:
        parser.error("Native Metal 4 tests require macOS 26 or newer")
    build.mkdir(parents=True, exist_ok=True)
    config = build / "unit-config"
    generated = build / "hw/xbox/nv2a/pgraph/metal"
    for directory in (config / "qapi", config / "trace", generated):
        directory.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    env["PYTHONPATH"] = str(build / "deps/python") + os.pathsep + env.get("PYTHONPATH", "")
    records = []

    def run(command, omit_output=False, **kwargs):
        result = subprocess.run(command, cwd=root, env=env, text=True,
                                capture_output=True, **kwargs)
        records.append({"command": [str(x) for x in command],
                        "exit_code": result.returncode,
                        "diagnostics": ("" if omit_output and not result.returncode
                                        else result.stdout + result.stderr)})
        (build / "native-unit-build.json").write_text(
            json.dumps(records, indent=2) + "\n")
        if result.returncode:
            print(result.stdout + result.stderr, file=sys.stderr)
            raise SystemExit(result.returncode)
        return result.stdout

    minimum = "-mmacosx-version-min=" + deployment
    # Check the actual host features selected below. Do not use an emulator's
    # generated configuration from a different checkout or fabricate structs.
    probe = r"""
        #include <stdint.h>
        #include <stdlib.h>
        #include <sys/uio.h>
        #if !defined(__APPLE__) || !defined(__aarch64__) || \
            __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
        #error Unsupported native test host
        #endif
        _Static_assert(sizeof(struct iovec) > 0, "iovec");
        __int128_t a;
        __uint128_t b;
        int main(void) {
            void *aligned = NULL;
            if (posix_memalign(&aligned, 64, 64)) return 1;
            free(aligned);
            uint64_t x = 0, y = 0;
            y = __atomic_load_n(&x, __ATOMIC_RELAXED);
            __atomic_store_n(&x, y, __ATOMIC_RELAXED);
            __atomic_compare_exchange_n(&x, &y, x, 0,
                __ATOMIC_RELAXED, __ATOMIC_RELAXED);
            __atomic_exchange_n(&x, y, __ATOMIC_RELAXED);
            __atomic_fetch_add(&x, y, __ATOMIC_RELAXED);
            a = a + b; b = a * b; a = a * a;
            return 0;
        }
    """
    run(["xcrun", "clang", minimum, "-Wall", "-Wextra", "-Werror",
         "-x", "c", "-", "-o", str(config / "host-probe")], input=probe)
    (config / "host-probe").unlink()
    (config / "config-host.h").write_text(
        "/* Isolated NV2A unit-test config; not a production emulator build. */\n" +
        "\n".join("#define " + name + " 1" for name in (
            "CONFIG_DARWIN", "CONFIG_POSIX", "HOST_AARCH64", "CONFIG_ATOMIC64",
            "CONFIG_IOVEC", "CONFIG_INT128_TYPE", "CONFIG_INT128", "CONFIG_TCG")) +
        "\n#define HOST_BIG_ENDIAN 0\n")
    if "renderer" in (args.target or []):
        with (config / "config-host.h").open("a") as stream:
            stream.write("#define CONFIG_POSIX_MEMALIGN 1\n")
            stream.write("#define CONFIG_QEMU_LOCALSTATEDIR " + json.dumps(str(build / "var")) + "\n")
            stream.write("#define CONFIG_PREFIX " + json.dumps(str(build)) + "\n")
            stream.write("#define CONFIG_BINDIR " + json.dumps(str(build)) + "\n")
    target = (root / "configs/targets/i386-softmmu.mak").read_text()
    assert "TARGET_ARCH=i386\n" in target and "TARGET_LONG_BITS=32\n" in target
    (config / "i386-softmmu-config-target.h").write_text(
        '#define TARGET_I386 1\n#define TARGET_NAME "i386"\n'
        '#define TARGET_LONG_BITS 32\n#define CONFIG_SOFTMMU 1\n')
    (config / "i386-softmmu-config-devices.h").write_text(
        "/* Isolated tests do not register QEMU devices. */\n")
    run([sys.executable, "scripts/qapi-gen.py", "-b", "-o",
         str(config / "qapi"), "qapi/qapi-schema.json"])
    run([sys.executable, "scripts/tracetool.py", "--format=h", "--backends=nop",
         "--group=hw_xbox_nv2a", "hw/xbox/nv2a/trace-events",
         str(config / "trace/trace-hw_xbox_nv2a.h")])
    run([sys.executable, "scripts/tracetool.py", "--format=h", "--backends=nop",
         "--group=util", "util/trace-events",
         str(config / "trace/trace-util.h")])
    if "renderer" in (args.target or []):
        for group in ("qom", "io", "migration", "qapi"):
            run([sys.executable, "scripts/tracetool.py", "--format=h", "--backends=nop",
                 "--group=" + group, group + "/trace-events",
                 str(config / "trace" / ("trace-" + group + ".h"))])
    run([sys.executable, str(build / "deps/genconfig/gen_config.py"),
         "config_spec.yml", str(config / "xemu-config.h")])
    for match in re.finditer(r"input: files\((.*?)\),\s*output: '([^']+-source.h)'",
                             (metal / "meson.build").read_text(), re.S):
        inputs = re.findall(r"'([^']+)'", match[1])
        source = run([sys.executable, str(metal / "shader-source.py"),
                      *[str(metal / p) for p in inputs]], omit_output=True)
        (generated / match[2]).write_text(source)
    imgui_dependency = build / "deps/imgui"
    if selected & ui_targets:
        for name, inputs in {
                "imgui": ["imgui.metal"],
                "decal": ["decal-uniforms.h", "decal.metal"]}.items():
            source = run([sys.executable, str(metal / "shader-source.py"),
                          *[str(root / "ui/xui/metal4" / p) for p in inputs]],
                         omit_output=True)
            (generated / (name + "-source.h")).write_text(source)
    if selected & {"ui-imgui", "ui-hazards"}:
        manifest = build / "deps/imgui-source.json"
        if not manifest.is_file():
            parser.error("UI tests require repository-pinned ImGui in BUILD/deps/imgui")
        dependency = json.loads(manifest.read_text())
        pinned = re.search(r"^revision\s*=\s*([0-9a-f]{40})$",
                           (root / "subprojects/imgui.wrap").read_text(), re.M)
        if (not pinned or dependency.get("revision") != pinned[1] or
                any(not (imgui_dependency / name).is_file() or
                    hashlib.sha256((imgui_dependency / name).read_bytes()).hexdigest() != digest
                    for name, digest in dependency["files"].items())):
            parser.error("UI tests require unchanged repository-pinned ImGui sources")
    cflags = shlex.split(run(["pkg-config", "--cflags", "glib-2.0"]))
    libs = shlex.split(run(["pkg-config", "--libs", "glib-2.0"]))
    common = ["xcrun", "clang", minimum, "-Wall", "-Wextra", "-Werror",
              # Matches QEMU's existing flag for TARGET_PAGE_MASK in headers.
              "-Wno-shift-negative-value", "-fblocks", "-DXBOX=1",
              "-DCOMPILING_PER_TARGET", '-DCONFIG_TARGET="i386-softmmu-config-target.h"',
              '-DCONFIG_DEVICES="i386-softmmu-config-devices.h"',
              "-I" + str(config), "-I" + str(build), "-I" + str(root),
              "-I" + str(generated)]
    for include in ("include", "host/include/aarch64", "host/include/generic",
                    "target/i386"):
        common += ["-isystem", str(root / include)]
    common += cflags
    if selected & {"ui-imgui", "ui-hazards"}:
        common += ["-isystem", str(imgui_dependency)]
    vsh_dependency = build / "deps/nv2a_vsh_cpu"
    if "renderer" in (args.target or []):
        expected = "561fe80da57a881f89000256b459440c0178a7ce"
        actual = run(["git", "-C", str(vsh_dependency), "rev-parse", "HEAD"]).strip()
        if actual != expected or run(["git", "-C", str(vsh_dependency), "status", "--porcelain"]).strip():
            parser.error("Renderer test requires the clean repository-pinned nv2a_vsh_cpu dependency")
        common += ["-I" + str(vsh_dependency / "src")]
    if "renderer" in selected or "ui-frame-images" in selected:
        common += ["-I" + str(root / "ui/thirdparty/fpng")]
        source = run([sys.executable, str(metal / "shader-source.py"),
                      str(root / "ui/xui/metal4/frame-images.metal")], omit_output=True)
        (generated / "frame-images-source.h").write_text(source)
    native = ["command", "lru-cache", "shader-library", "texture-snapshot-pgraph", "texture-cache",
              "texture-sampler", "texture-upload", "texture-snapshot",
              "surface-cache", "surface-transfer", "clear", "pixel-shader",
              "pixel-combiner", "draw-state"]
    # Content-based cache: generated headers may be rewritten with identical
    # bytes. A compiler/SDK/flags or header change invalidates all affected
    # recipes; a source change invalidates its own object. No mtime shortcuts.
    header_names = run(["git", "ls-files", "-z", "--cached", "--others",
                        "--exclude-standard"], omit_output=True).split("\0")
    header_paths = [root / name for name in header_names
                    if name.endswith((".h", ".hh", ".hpp", ".inc")) and (root / name).is_file()]
    header_paths += list(config.rglob("*.h")) + list(generated.glob("*.h"))
    if "renderer" in (args.target or []):
        header_paths += list(vsh_dependency.rglob("*.h"))
    if selected & {"ui-imgui", "ui-hazards"}:
        header_paths += list(imgui_dependency.rglob("*.h"))
    headers = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
               for p in sorted(set(header_paths))}
    toolchain = run(["xcrun", "clang", "--version"])
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
    header_key = hashlib.sha256(json.dumps([toolchain, sdk, headers], sort_keys=True).encode()).hexdigest()
    compiled = {}
    for target in args.target or ["texture-cache", "texture-pgraph"]:
        test = {"ui-decal": "test-xemu-metal-decal.m",
                "ui-imgui": "test-xemu-metal-imgui.mm",
                "ui-hazards": "test-nv2a-metal-ui-hazards.mm",
                "ui-frame-images": "test-xemu-metal-frame-images.mm"}.get(
                    target, "test-nv2a-metal-" + target + ".m")
        sources = [root / "tests/unit" / test]
        sources += [metal / (name + ".m") for name in native]
        if target in ui_targets:
            sources = [sources[0], metal / "command.m"]
            if target in ("ui-decal", "ui-hazards"):
                sources += [root / "ui/xui/metal4/decal.m"]
            if target in ("ui-imgui", "ui-hazards"):
                sources += [metal / "display.m", root / "ui/xui/metal4/imgui-renderer.mm"]
                sources += [imgui_dependency / (name + ".cpp") for name in (
                    "imgui", "imgui_draw", "imgui_tables", "imgui_widgets")]
            if target == "ui-hazards":
                sources += [metal / "vga.m"]
            if target == "ui-frame-images":
                sources += [metal / "display.m", root / "ui/xui/metal4/frame-images.mm",
                            root / "ui/thirdparty/fpng/fpng.cpp"]
        if target == "vga":
            sources = [sources[0], metal / "command.m", metal / "vga.m"]
        if target in ("vertex-fetch", "fetch-pgraph", "pending-pgraph"):
            sources += [metal / (name + ".m") for name in (
                "vertex-fetch", "vertex-fixed", "vertex-program")]
        if target == "pending-journal":
            sources = [sources[0], metal / "pending-journal.m"]
        if target == "pending-archive":
            sources = [sources[0], metal / "pending-archive.m", metal / "pending-journal.m"]
        if target == "pixel-pgraph":
            sources += [metal / "pixel-pgraph.m", metal / "texture-pgraph.m", metal.parent / "texture.c"]
        if target in ("vertex-capture", "vertex-constant-epoch"):
            sources += [metal / (name + ".m") for name in (
                "vertex-pgraph", "vertex-writable", "vertex-program", "vertex-fixed")]
        if target == "vertex-fixed":
            sources += [metal / "vertex-fixed.m", metal / "geometry.m"]
        if target == "vertex-state":
            sources += [metal / "vertex-state.m"]
        if target == "vertex-writable":
            sources += [metal / "vertex-writable.m"]
        if target == "vertex-epoch":
            sources += [metal / (name + ".m") for name in (
                "vertex-epoch", "vertex-fetch", "vertex-fixed", "vertex-program",
                "vertex-pgraph", "vertex-writable", "geometry")]
        if target == "pending-pgraph":
            sources += [metal / "pending-pgraph.m", metal / "pending-journal.m"]
        if target == "fetch-pgraph":
            sources += [metal / (name + ".m") for name in (
                "fetch-pgraph", "vertex-pgraph", "vertex-writable",
                "pixel-pgraph", "geometry", "pending-journal")]
        if target in ("scanout", "display", "scanout-hazards"):
            sources += [metal / "scanout.m", metal / "display.m"]
        if target in ("surface-cache", "blit", "transfer-uniforms"):
            sources += [metal / "blit.m"]
        if target in ("pending-native", "vertex-slices", "archive-native"):
            sources += [metal / (name + ".m") for name in (
                "vertex-stream", "pending-native", "pending-journal")]
        if target == "archive-native":
            sources += [metal / (name + ".m") for name in (
                "archive-native", "pending-archive", "vertex-program")]
        if target == "pixel-shader":
            sources += [metal / (name + ".m") for name in (
                "geometry", "vertex-fetch", "vertex-program")]
        if target in ("visibility", "geometry", "lines", "polygons", "direct-points", "direct-lines", "direct-triangles", "vertex-slices"):
            sources += [metal / "geometry.m"]
        if target in ("texture-pgraph", "draw-pgraph", "renderer"):
            sources += [metal / "texture-pgraph.m", metal.parent / "texture.c"]
        if target in ("draw-pgraph", "renderer"):
            sources += [metal / (name + ".m") for name in (
                "draw-pgraph", "surface-pgraph", "reports-pgraph", "blit-pgraph",
                "blit", "fetch-pgraph", "vertex-fetch", "vertex-pgraph",
                "vertex-state", "vertex-epoch",
                "vertex-fixed", "vertex-program", "vertex-writable",
                "input-checkpoint", "pending-pgraph", "pending-native",
                "pending-journal", "pending-archive", "vertex-stream",
                "state-pgraph", "archive-native", "pixel-pgraph", "geometry", "pending-journal")]
            sources += [root / name for name in (
                "util/qemu-thread-posix.c", "util/error-report.c",
                "util/event.c", "util/qsp.c", "util/notify.c",
                "stubs/monitor-core.c",
                "stubs/iothread-lock.c", "stubs/error-printf.c")]
        if target == "renderer":
            sources += [metal / (name + ".m") for name in (
                "renderer", "scanout-pgraph", "scanout", "display", "vga")]
            sources += [metal / "save-lifecycle.c", metal / "vertex-snapshot.c",
                        root / "ui/xui/metal4/frame-images.mm", root / "ui/thirdparty/fpng/fpng.cpp"]
            sources += [root / ("hw/xbox/nv2a/pgraph/" + name) for name in (
                "pgraph.c", "vertex.c", "glsl/vsh.c", "glsl/vsh-ff.c", "glsl/vsh-prog.c", "glsl/common.c")]
            sources += [vsh_dependency / "src" / name for name in (
                "nv2a_vsh_cpu.c", "nv2a_vsh_disassembler.c", "nv2a_vsh_emulator.c",
                "nv2a_vsh_emulator_execution_state.c")]
            sources += [root / name for name in (
                "qom/container.c", "qom/object.c", "qom/object_interfaces.c", "qom/qom-qobject.c",
                "migration/migration-stats.c", "migration/vmstate-types.c", "migration/vmstate.c", "migration/qemu-file.c",
                "io/channel.c", "io/channel-file.c", "io/channel-util.c", "io/channel-watch.c", "io/task.c",
                "util/error.c", "util/module.c", "util/cutils.c", "util/host-utils.c", "util/memalign.c",
                "util/bitmap.c", "util/bitops.c", "util/unicode.c", "util/osdep.c",
                "util/thread-pool.c", "util/qemu-timer-common.c",
                "util/oslib-posix.c", "util/iov.c", "util/notify.c", "util/path.c",
                "util/qemu-print.c", "util/qemu-sockets.c", "util/rcu.c", "util/lockcnt.c", "util/async.c",
                "util/aiocb.c", "util/aio-wait.c", "util/main-loop.c", "util/qemu-timer.c",
                "util/event_notifier-posix.c", "util/aio-posix.c", "util/fdmon-poll.c",
                "util/qemu-coroutine.c", "util/qemu-coroutine-lock.c", "util/qemu-coroutine-io.c", "util/coroutine-sigaltstack.c",
                "qobject/qobject.c", "qobject/qnum.c", "qobject/qstring.c", "qobject/qlist.c", "qobject/qdict.c",
                "qobject/qbool.c", "qobject/qnull.c", "qobject/json-writer.c", "qobject/json-parser.c", "qobject/json-lexer.c", "qobject/json-streamer.c", "qobject/qjson.c",
                "qapi/qapi-visit-core.c", "qapi/qapi-clone-visitor.c", "qapi/qapi-dealloc-visitor.c", "qapi/qobject-input-visitor.c",
                "qapi/qobject-output-visitor.c", "qapi/string-input-visitor.c", "qapi/string-output-visitor.c", "qapi/qapi-forward-visitor.c",
                "stubs/cpu-get-clock.c", "stubs/fdset.c", "stubs/is-daemonized.c", "stubs/replay-mode.c",
                "stubs/trace-control.c", "stubs/replay-tools.c", "stubs/cpus-virtual-clock.c", "stubs/icount.c",
                "stubs/qemu-timer-notify-cb.c", "stubs/monitor-internal.c", "stubs/qtest.c", "stubs/vm-stop.c",
                "stubs/graph-lock.c")]
            sources += sorted((config / "qapi").glob("qapi-types-*.c"))
            sources += sorted((config / "qapi").glob("qapi-visit-*.c"))
        sources = list(dict.fromkeys(sources))
        objects = []
        for source in sources:
            if source.is_relative_to(root):
                relative = source.relative_to(root)
            else:
                relative = Path("build-dependency") / source.relative_to(build)
            obj = build / "objects" / relative.with_suffix(source.suffix + ".o")
            obj.parent.mkdir(parents=True, exist_ok=True)
            if source not in compiled:
                flags = common + (["-fobjc-arc"] if source.suffix in (".m", ".mm") else [])
                if source.suffix in (".cpp", ".mm"):
                    flags += ["-std=c++17"]
                if source.is_relative_to(imgui_dependency):
                    # The pinned fork disables windowing navigation but keeps
                    # its static implementation. Its zero-length text edit
                    # also passes an unread placeholder to the bundled stb.
                    # Keep these vendor-only exceptions out of project code.
                    flags += ["-Wno-unused-function", "-Wno-uninitialized-const-pointer"]
                if source.name == "fpng.cpp":
                    # Keep the vendor assertions enabled. Its scalar little-endian
                    # helpers and always-true uint8 assertion trigger these two
                    # diagnostics in current Clang; do not relax Metal/test flags.
                    flags += ["-DFPNG_NO_SSE=1", "-Wno-unused-function",
                              "-Wno-tautological-constant-out-of-range-compare"]
                if source.suffix == ".c":
                    # Unmodified QEMU helpers use their normal warning level,
                    # including meson.build's designated-initializer setting.
                    flags = [f for f in common if f != "-Wextra"]
                    flags += ["-Wno-initializer-overrides"]
                command = flags + ["-c", str(source), "-o", str(obj)]
                digest = hashlib.sha256(source.read_bytes()).hexdigest()
                recipe = {"command": command, "source_sha256": digest, "headers_sha256": header_key}
                cache = obj.with_suffix(obj.suffix + ".json")
                cached = False
                if obj.is_file() and cache.is_file():
                    previous = json.loads(cache.read_text())
                    cached = (previous.get("recipe") == recipe and
                              previous.get("object_sha256") == hashlib.sha256(obj.read_bytes()).hexdigest())
                if cached:
                    records.append({"command": command, "exit_code": 0,
                                    "diagnostics": "", "cache_verified": True})
                else:
                    run(command)
                    cache.write_text(json.dumps({"recipe": recipe, "object_sha256": hashlib.sha256(obj.read_bytes()).hexdigest()}, indent=2) + "\n")
                compiled[source] = digest
            objects.append(str(obj))
        ui_frameworks = ["-framework", "CoreGraphics"] if target in ui_targets else []
        run(["xcrun", "clang++" if target in ("renderer", "ui-imgui", "ui-hazards", "ui-frame-images") else "clang", minimum, "-Wl,-fatal_warnings", "-Wl,-dead_strip", *objects, *libs,
             "-framework", "Foundation", "-framework", "Metal", "-framework",
             "QuartzCore", *ui_frameworks, "-o", str(build / ("test-nv2a-metal-" + target))])
        print("Built without launching: test-nv2a-metal-" + target, flush=True)
    (build / "native-unit-inputs.json").write_text(json.dumps(
        {str(p.relative_to(root)) if p.is_relative_to(root) else
         "@build/" + str(p.relative_to(build)): h for p, h in compiled.items()}, indent=2) + "\n")


if __name__ == "__main__":
    main()
