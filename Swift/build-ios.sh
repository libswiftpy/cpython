#!/bin/bash
# Cross-compiles CPython for iOS and stages headers and a static libpython
# into Swift/.cpython-dist-<sdk>.
#
# configure refuses a non-framework iOS build ("iOS builds must use
# --enable-framework"), but the framework is linked *from* a static
# libpython.a, and that archive is what we keep — no framework to embed and
# sign, and no XCframework.
#
#   ./Swift/build-ios.sh simulator   # arm64 iOS simulator (default)
#   ./Swift/build-ios.sh device      # arm64 iOS device
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "${1:-simulator}" in
    simulator) HOST=arm64-apple-ios-simulator; SDK=iphonesimulator ;;
    device)    HOST=arm64-apple-ios;           SDK=iphoneos ;;
    *) echo "usage: build-ios.sh [simulator|device]" >&2; exit 1 ;;
esac

# One staging directory per SDK, so both slices can be present at once. Which
# one gets linked is decided in Xcode — see the README: SwiftPM cannot tell a
# simulator destination from a device one.
DIST="$ROOT/Swift/.cpython-dist-$SDK"
BUILD_DIR="$ROOT/cross-build/$HOST"
BUILD_PYTHON="$ROOT/cross-build/$(uname -m)-apple-darwin/python.exe"

[ -x "$BUILD_PYTHON" ] || { echo "run Swift/build.sh first: the cross-build needs a host python" >&2; exit 1; }

# CPython's own cross-compiler wrappers, named after the target triples.
export PATH="$ROOT/Platforms/Apple/iOS/Resources/bin:$PATH"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
if [ ! -f Makefile ]; then
    "$ROOT/configure" \
        --host="$HOST" \
        --build="$(uname -m)-apple-darwin" \
        --with-build-python="$BUILD_PYTHON" \
        --enable-framework="$BUILD_DIR/Frameworks" \
        --disable-test-modules \
        --without-ensurepip \
        --without-doc-strings
fi

VERSION=$(sed -n 's/^VERSION=[[:space:]]*//p' Makefile | head -1)
make -j"$(sysctl -n hw.ncpu)" "libpython$VERSION.a"

rm -rf "$DIST"
mkdir -p "$DIST/include/python" "$DIST/lib"
cp -R "$ROOT/Include/." "$DIST/include/python/"
cp pyconfig.h "$DIST/include/python/pyconfig.h"
cp "libpython$VERSION.a" "$DIST/lib/libpython.a"

# What this slice needs alongside libpython, straight from its Makefile.
sed -n 's/^LIBS=[[:space:]]*//p' Makefile | head -1 > "$DIST/link-flags.txt"

echo "staged $DIST for CPython $VERSION / $HOST ($(du -sh "$DIST" | cut -f1))"
echo "extra link flags: $(cat "$DIST/link-flags.txt")"
