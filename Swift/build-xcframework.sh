#!/bin/bash
# Builds libpython for the Apple SDKs and packs it as PythonCore.xcframework,
# which Package.swift downloads from a release; and refreshes Swift/Headers.
# Run it for a new CPython or a change to its core (Include, Objects, Parser,
# Python, or a module linked into libpython), not for Lib or Modules/_swiftpy.
#
#   ./Swift/build-xcframework.sh           # builds all five SDKs first
#   ./Swift/build-xcframework.sh --pack    # packs what is staged already
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Swift/.cpython-dist-xcframework"
HEADERS="$ROOT/Swift/Headers/python"
SDKS=(macosx iphoneos iphonesimulator xros xrsimulator)

if [ "${1:-}" != "--pack" ]; then
    "$ROOT/Swift/build.sh"
    for platform in ios visionos; do
        "$ROOT/Swift/build-$platform.sh" simulator
        "$ROOT/Swift/build-$platform.sh" device
    done
fi

dist() { if [ "$1" = macosx ]; then echo "$ROOT/Swift/.cpython-dist"; else echo "$ROOT/Swift/.cpython-dist-$1"; fi; }

# One set of headers: only pyconfig.h differs by SDK, so each one's is kept
# under its name and pyconfig.h picks.
rm -rf "$HEADERS" "$OUT"
mkdir -p "$HEADERS" "$OUT"
(cd "$ROOT/Include" && find . -name '*.h' | while read -r header; do
    mkdir -p "$HEADERS/$(dirname "$header")"
    cp "$header" "$HEADERS/$header"
done)
ARGS=()
for sdk in "${SDKS[@]}"; do
    source="$(dist "$sdk")"
    [ -f "$source/lib/libpython.a" ] || { echo "CPython is not staged for $sdk" >&2; exit 1; }
    cp "$source/include/python/pyconfig.h" "$HEADERS/pyconfig-$sdk.h"
    # Not libpython.a: Xcode puts it in the products directory, where the
    # package's own libPython.a is the same file on a case-insensitive disk.
    mkdir -p "$OUT/$sdk"
    cp "$source/lib/libpython.a" "$OUT/$sdk/libPythonCore.a"
    ARGS+=(-library "$OUT/$sdk/libPythonCore.a")
done
cat > "$HEADERS/pyconfig.h" <<'HEADER'
/* Made by Swift/build-xcframework.sh: the configuration of the SDK being built for. */
#include <TargetConditionals.h>

#if TARGET_OS_VISION && TARGET_OS_SIMULATOR
#include "pyconfig-xrsimulator.h"
#elif TARGET_OS_VISION
#include "pyconfig-xros.h"
#elif TARGET_OS_SIMULATOR
#include "pyconfig-iphonesimulator.h"
#elif TARGET_OS_IPHONE
#include "pyconfig-iphoneos.h"
#else
#include "pyconfig-macosx.h"
#endif
HEADER

xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT/PythonCore.xcframework" > /dev/null
(cd "$OUT" && zip -qry PythonCore.xcframework.zip PythonCore.xcframework)
echo "staged $OUT/PythonCore.xcframework.zip ($(du -h "$OUT/PythonCore.xcframework.zip" | cut -f1 | xargs)), checksum $(swift package --package-path "$ROOT" compute-checksum "$OUT/PythonCore.xcframework.zip")"
