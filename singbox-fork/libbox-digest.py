#!/usr/bin/env python3
"""Deterministic SHA-256 of a Libbox static library (T-ARCH-31).

`gomobile bind` emits a Mach-O `ar` archive. Two builds of identical source differ in
exactly one field: the mtime in the `__.SYMDEF` member header that `libtool` stamps with
the build time. Blanking every member mtime makes the digest reproducible, so a third
party can rebuild from the published source and compare against a fixed number.
"""
import hashlib, sys

MAGIC = b"!<arch>\n"

def canonicalise(data: bytes) -> bytes:
    b = bytearray(data)
    start = b.find(MAGIC)
    if start < 0:
        return bytes(b)
    pos = start + len(MAGIC)
    while pos + 60 <= len(b):
        header = bytes(b[pos:pos + 60])
        if header[58:60] != b"`\n":
            break
        try:
            size = int(header[48:58].decode().strip())
        except ValueError:
            break
        b[pos + 16:pos + 28] = b" " * 12          # mtime field
        pos += 60 + size
        if size % 2:
            pos += 1
    return bytes(b)

for path in sys.argv[1:]:
    with open(path, "rb") as fh:
        print(hashlib.sha256(canonicalise(fh.read())).hexdigest(), path)
