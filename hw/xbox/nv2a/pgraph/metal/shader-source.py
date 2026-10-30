#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.0-or-later

"""Embed shared C/MSL declarations and source as a null-terminated byte array."""

from pathlib import Path
import sys


def main():
    source = bytearray()
    for filename in sys.argv[1:]:
        for line in Path(filename).read_text(encoding="utf-8").splitlines():
            source.extend((line + "\n").encode("utf-8"))
    source.append(0)
    # Character initializers avoid ISO C's limit on concatenated string literals
    # without weakening warnings for the Objective-C consumers.
    print("static const char metal_shader_source[] = {")
    for offset in range(0, len(source), 16):
        print("    " + ", ".join("'\\x%02x'" % byte
                                  for byte in source[offset:offset + 16]) + ",")
    print("};")


if __name__ == "__main__":
    main()
