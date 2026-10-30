#!/usr/bin/env python3
"""Expose the original private report VMSD in an isolated native test TU."""

import hashlib
import json
from pathlib import Path
import sys


def generate(path):
    source = Path(path).read_text()
    start_marker = "static int metal4_report_size_get("
    end_marker = "static const VMStateDescription vmstate_nv2a ="
    if source.count(start_marker) != 1 or source.count(end_marker) != 1:
        raise ValueError("Production report VMSD boundaries changed")
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    block = source[start:end]
    required = (
        "metal4_report_size_get", "metal4_report_size_put",
        "vmstate_info_metal4_report_size", "metal4_reports_needed",
        "metal4_reports_post_load", "vmstate_nv2a_metal4_reports",
        "VMSTATE_VBUFFER_ALLOC_UINT32",
    )
    if not all(name in block for name in required):
        raise ValueError("Incomplete production report definitions")
    prefix = (
        '#include "qemu/osdep.h"\n'
        '#include "hw/xbox/nv2a/nv2a_int.h"\n'
        '#include "hw/xbox/nv2a/pgraph/metal/renderer.h"\n'
        '#include "migration/qemu-file.h"\n'
        '#include "qemu/bswap.h"\n'
        '#pragma clang diagnostic ignored "-Wnull-pointer-subtraction"\n'
        f'/* Original source SHA256: {hashlib.sha256(source.encode()).hexdigest()} */\n'
        f'#line {source[:start].count(chr(10)) + 1} {json.dumps(str(Path(path).resolve()))}\n'
    )
    suffix = (
        '\nconst VMStateDescription *test_metal_report_vmsd(void)\n'
        '{\n    return &vmstate_nv2a_metal4_reports;\n}\n'
    )
    return prefix + block + suffix


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: test-metal-report-source.py NV2A_SOURCE")
    sys.stdout.write(generate(sys.argv[1]))
