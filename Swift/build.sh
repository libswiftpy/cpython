#!/bin/bash
# Builds CPython for the host (macOS) and stages headers and libpython in
# Swift/.cpython-dist, then the parts of Lib the package ships, as stage.sh does.
# Only a change to CPython itself needs it; see build-xcframework.sh.
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
        --without-remote-debug  # sys.remote_exec: task_for_pid, useless embedded
fi
# No git stamp in sys.version, "(main, <date>)" as a release build has: out of
# tree, `git describe` reads every file as missing and stamps "-dirty".
make -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" GITVERSION=true GITTAG=true GITBRANCH=true

VERSION=$(./python.exe -c 'import sys; print("%d.%d" % sys.version_info[:2])')

rm -rf "$DIST"
mkdir -p "$DIST/include/python" "$DIST/lib"

# Headers: the public API plus the generated pyconfig.h next to it. The package
# compiles against Swift/Headers, which build-xcframework.sh makes from these.
cp -R "$ROOT/Include/." "$DIST/include/python/"
cp pyconfig.h "$DIST/include/python/pyconfig.h"

# The interpreter, likewise under a fixed name.
cp "libpython$VERSION.a" "$DIST/lib/libpython.a"

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
echo "link flags: $(cat "$DIST/link-flags.txt")"

# The parts of Lib the package ships, with the python built above.
"$ROOT/Swift/stage.sh"
