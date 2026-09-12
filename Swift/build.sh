#!/bin/bash
# Builds CPython for the host (macOS) and stages what a Swift program needs to
# embed it: headers and libpython in Swift/.cpython-dist, and the minimal
# stdlib in the Python target's resources.
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
        --without-doc-strings
fi
make -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

VERSION=$(./python.exe -c 'import sys; print("%d.%d" % sys.version_info[:2])')

# Each stdlib module is staged inside its own Swift target, where SwiftPM picks
# it up as a resource; everything else is a build input and stays in $DIST.
ENCODINGS_DIR="$ROOT/Swift/Sources/encodings/encodings"
APPLE_SUPPORT_DIR="$ROOT/Swift/Sources/_apple_support"
STDLIB_DIR="$ROOT/Swift/Sources/stdlib/stdlib"

rm -rf "$DIST" "$ENCODINGS_DIR" "$STDLIB_DIR"
mkdir -p "$DIST/include/python" "$DIST/lib" "$ENCODINGS_DIR" "$STDLIB_DIR"

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

# 3.16 and later only; `encodings` does not reach for it before that.
if [ -f "$ROOT/Lib/encodings/_iconv_codecs.py" ]; then
    cp "$ROOT/Lib/encodings/_iconv_codecs.py" "$ENCODINGS_DIR/"
fi

# iOS routes stdout and stderr through the system log, via this module.
cp "$ROOT/Lib/_apple_support.py" "$APPLE_SUPPORT_DIR/"

# The pure-Python stdlib the package ships. functools and everything it
# reaches at import time, plus what `collections` defers with 3.15's lazy
# import -- copy and heapq are needed the moment Counter.most_common or
# OrderedDict.copy is called. None of these needs a C module of its own:
# heapq falls back to its Python path when _heapq is absent.
# inspect and what it imports come next: rlcompleter and help() read
# signatures through it. re and tokenize are its lazy imports, left out.
# datetime uses the _datetime builtin already linked into libpython.
STDLIB_MODULES=(
    functools operator types reprlib keyword datetime random bisect pkgutil
    copy copyreg weakref _weakrefset heapq
    inspect enum dis ast _ast_unparse _colorize dataclasses contextlib annotationlib opcode token tokenize _opcode_metadata
    typing
)
# json falls back to its Python scanner without _json; re needs only _sre.
STDLIB_PACKAGES=(collections importlib json re)
for module in "${STDLIB_MODULES[@]}"; do
    cp "$ROOT/Lib/$module.py" "$STDLIB_DIR/"
done
for package in "${STDLIB_PACKAGES[@]}"; do
    cp -R "$ROOT/Lib/$package" "$STDLIB_DIR/"
done
# The `python -m json.tool` CLI, which drags argparse in.
rm -f "$STDLIB_DIR/json/tool.py"

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
find "$ENCODINGS_DIR" "$APPLE_SUPPORT_DIR" "$STDLIB_DIR" -name __pycache__ -type d \
    -exec rm -rf {} + 2>/dev/null || true

echo "staged $DIST for CPython $VERSION ($(du -sh "$DIST" | cut -f1))"
echo "staged encodings ($(du -sh "$ENCODINGS_DIR" | cut -f1))"
echo "staged stdlib ($(du -sh "$STDLIB_DIR" | cut -f1))"
echo "link flags: $(cat "$DIST/link-flags.txt")"
