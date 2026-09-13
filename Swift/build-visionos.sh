#!/bin/bash
# Cross-compiles CPython for visionOS and stages headers and a static libpython
# into Swift/.cpython-dist-<sdk>.
#
# configure treats visionOS as iOS (sys.platform is "ios" there too); only the
# host triple and the SDK differ. See build-ios.sh for why a framework build.
#
#   ./Swift/build-visionos.sh simulator   # arm64 visionOS simulator (default)
#   ./Swift/build-visionos.sh device      # arm64 visionOS device
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "${1:-simulator}" in
    simulator) HOST=arm64-apple-xros-simulator; SDK=xrsimulator ;;
    device)    HOST=arm64-apple-xros;           SDK=xros ;;
    *) echo "usage: build-visionos.sh [simulator|device]" >&2; exit 1 ;;
esac

# One staging directory per SDK, so both slices can be present at once. Which
# one gets linked is decided in Xcode — see the README: SwiftPM cannot tell a
# simulator destination from a device one.
DIST="$ROOT/Swift/.cpython-dist-$SDK"
BUILD_DIR="$ROOT/cross-build/$HOST"
BUILD_PYTHON="$ROOT/cross-build/$(uname -m)-apple-darwin/python.exe"

[ -x "$BUILD_PYTHON" ] || { echo "run Swift/build.sh first: the cross-build needs a host python" >&2; exit 1; }

# CPython's own cross-compiler wrappers, named after the target triples.
export PATH="$ROOT/Platforms/Apple/visionOS/Resources/bin:$PATH"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
# The SDK declares these, but the platform never lets a process spawn another,
# so leave os.fork and friends out of the build rather than out of reach.
export ac_cv_func_fork=no ac_cv_func_fork1=no ac_cv_func_vfork=no ac_cv_func_forkpty=no ac_cv_lib_util_forkpty=no \
       ac_cv_func_execv=no ac_cv_func_posix_spawn=no ac_cv_func_posix_spawnp=no \
       ac_cv_func_chroot=no ac_cv_func_setuid=no ac_cv_func_setgid=no
if [ ! -f Makefile ]; then
    "$ROOT/configure" \
        --host="$HOST" \
        --build="$(uname -m)-apple-darwin" \
        --with-build-python="$BUILD_PYTHON" \
        --enable-framework="$BUILD_DIR/Frameworks" \
        --disable-test-modules \
        --without-ensurepip \
        --without-doc-strings \
        --without-remote-debug
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
