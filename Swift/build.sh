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

# The stdlib is staged inside the Python target, where SwiftPM picks it up as
# a resource; everything else is a build input and stays in $DIST.
HOME_DIR="$ROOT/Swift/Sources/Python/PythonHome"

rm -rf "$DIST" "$HOME_DIR/lib"
mkdir -p "$DIST/include/python" "$DIST/lib" "$HOME_DIR/lib/python$VERSION/encodings"

# Headers: the public API plus the generated pyconfig.h next to it, so that
# Python.h resolves every #include relative to itself and Swift needs no -I.
# The directory is unversioned, so the module map never has to be updated.
cp -R "$ROOT/Include/." "$DIST/include/python/"
cp pyconfig.h "$DIST/include/python/pyconfig.h"

# The interpreter, likewise under a fixed name.
cp "libpython$VERSION.a" "$DIST/lib/libpython.a"

# Minimal stdlib, copied into the app bundle by SwiftPM. Everything else the
# interpreter needs at start-up (os, io, abc, codecs, site, ...) is frozen into
# libpython; `encodings` is the only package still imported from disk.
# iOS routes stdout and stderr through the system log, via this module.
cp "$ROOT/Lib/_apple_support.py" "$HOME_DIR/lib/python$VERSION/"

cp "$ROOT"/Lib/encodings/__init__.py \
   "$ROOT"/Lib/encodings/aliases.py \
   "$ROOT"/Lib/encodings/_iconv_codecs.py \
   "$ROOT"/Lib/encodings/utf_8.py \
   "$ROOT"/Lib/encodings/latin_1.py \
   "$ROOT"/Lib/encodings/ascii.py \
   "$HOME_DIR/lib/python$VERSION/encodings/"

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

echo "staged $DIST for CPython $VERSION ($(du -sh "$DIST" | cut -f1))"
echo "staged $HOME_DIR/lib/python$VERSION ($(du -sh "$HOME_DIR" | cut -f1))"
echo "link flags: $(cat "$DIST/link-flags.txt")"
