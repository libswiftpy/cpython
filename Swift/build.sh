#!/bin/bash
# Builds CPython for the host (macOS) and stages what a Swift program needs to
# embed it: headers and libpython in Swift/.cpython-dist, and the stdlib the
# interpreter needs before sys.path is set, as target resources.
#
# The build is out of tree, in cross-build/<triple>, because an iOS build needs
# a clean source tree — see Swift/build-ios.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/Swift/.cpython-dist"
BUILD_DIR="$ROOT/cross-build/$(uname -m)-apple-darwin"

# Match the minimum macOS version declared in Package.swift, otherwise the
# linker warns about every object file in libpython.
export MACOSX_DEPLOYMENT_TARGET=13.0

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
if [ ! -f Makefile ]; then
    "$ROOT/configure" --prefix="$DIST" \
        --disable-shared \
        --disable-test-modules \
        --without-ensurepip \
        --without-doc-strings \
        --without-remote-debug  # sys.remote_exec: task_for_pid, useless embedded
fi
make -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

VERSION=$(./python.exe -c 'import sys; print("%d.%d" % sys.version_info[:2])')

# Each stdlib module is staged inside its own Swift target, where SwiftPM picks
# it up as a resource; everything else is a build input and stays in $DIST.
ENCODINGS_DIR="$ROOT/Swift/Sources/encodings/encodings"
APPLE_SUPPORT_DIR="$ROOT/Swift/Sources/_apple_support"

rm -rf "$DIST" "$ENCODINGS_DIR"
mkdir -p "$DIST/include/python" "$DIST/lib" "$ENCODINGS_DIR"

# Headers: the public API plus the generated pyconfig.h next to it, so that
# Python.h resolves every #include relative to itself and Swift needs no -I.
# The directory is unversioned, so the module map never has to be updated.
cp -R "$ROOT/Include/." "$DIST/include/python/"
cp pyconfig.h "$DIST/include/python/pyconfig.h"

# The interpreter, likewise under a fixed name.
cp "libpython$VERSION.a" "$DIST/lib/libpython.a"

# Minimal stdlib. Everything else the interpreter needs at start-up (os, io,
# abc, codecs, site, ...) is frozen into libpython; these are the only modules
# still imported from disk.
cp "$ROOT"/Lib/encodings/__init__.py \
   "$ROOT"/Lib/encodings/aliases.py \
   "$ROOT"/Lib/encodings/utf_8.py \
   "$ROOT"/Lib/encodings/latin_1.py \
   "$ROOT"/Lib/encodings/ascii.py \
   "$ENCODINGS_DIR/"
# The rest a text app meets in the wild, 140 KB: UTF-16/32 and BOM-prefixed
# UTF-8 for files, cp1252 and mac_roman for legacy text, cp437 for zip entry
# names, idna for URLs, the escape codecs for str methods. CJK code pages need C codecs and stay out.
cp "$ROOT"/Lib/encodings/utf_8_sig.py \
   "$ROOT"/Lib/encodings/utf_16.py "$ROOT"/Lib/encodings/utf_16_be.py "$ROOT"/Lib/encodings/utf_16_le.py \
   "$ROOT"/Lib/encodings/utf_32.py "$ROOT"/Lib/encodings/utf_32_be.py "$ROOT"/Lib/encodings/utf_32_le.py \
   "$ROOT"/Lib/encodings/cp1252.py "$ROOT"/Lib/encodings/mac_roman.py "$ROOT"/Lib/encodings/charmap.py \
   "$ROOT"/Lib/encodings/cp437.py \
   "$ROOT"/Lib/encodings/idna.py "$ROOT"/Lib/encodings/punycode.py \
   "$ROOT"/Lib/encodings/unicode_escape.py "$ROOT"/Lib/encodings/raw_unicode_escape.py \
   "$ENCODINGS_DIR/"

# 3.16 and later only; `encodings` does not reach for it before that.
if [ -f "$ROOT/Lib/encodings/_iconv_codecs.py" ]; then
    cp "$ROOT/Lib/encodings/_iconv_codecs.py" "$ENCODINGS_DIR/"
fi

# iOS routes stdout and stderr through the system log, via this module.
cp "$ROOT/Lib/_apple_support.py" "$APPLE_SUPPORT_DIR/"

# The rest of the pure-Python stdlib is zipped at build time by the
# StageStdlib plugin, from Swift/Sources/stdlib/modules.txt, with the python
# built above.

# Link flags, read out of CPython's own build configuration rather than
# hard-coded per platform; compare them with Package.swift if linking fails.
./python.exe -c '
import sysconfig
flags = ["-lpython"]
for variable in ("LIBS", "LINKFORSHARED"):
    for flag in (sysconfig.get_config_var(variable) or "").split():
        # swiftc drives the linker itself and takes -Xlinker, not -Wl,.
        expanded = []
        if flag.startswith("-Wl,"):
            for argument in flag[4:].split(","):
                expanded += ["-Xlinker", argument]
        else:
            expanded = [flag]
        for argument in expanded:
            if argument not in flags or argument == "-Xlinker":
                flags.append(argument)
print(" ".join(flags))
' > "$DIST/link-flags.txt"

# Bytecode caches would ship as dead weight in the resource bundles.
find "$ENCODINGS_DIR" "$APPLE_SUPPORT_DIR" -name __pycache__ -type d \
    -exec rm -rf {} + 2>/dev/null || true

echo "staged $DIST for CPython $VERSION ($(du -sh "$DIST" | cut -f1))"
echo "staged encodings ($(du -sh "$ENCODINGS_DIR" | cut -f1))"
echo "link flags: $(cat "$DIST/link-flags.txt")"
