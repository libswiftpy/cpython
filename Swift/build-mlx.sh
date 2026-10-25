#!/bin/bash
# Builds MLX's mlx.core for the Apple SDKs and stages it for the mlx trait:
# Swift/.mlx-dist/MLXCore.xcframework, a static library per SDK with MLX
# linked in, each Metal platform's kernels as Swift/Sources/mlx_metal_*/
# default.metallib, and the mlx Python package as Swift/Sources/mlx/mlx.zip.
#
#   ./Swift/build-mlx.sh                          # all five SDKs
#   ./Swift/build-mlx.sh macosx iphonesimulator   # just these
#
# Needs CPython staged for the same SDKs first (build.sh, build-ios.sh,
# build-visionos.sh): mlx.core compiles against each one's headers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MLX_VERSION=v0.32.4
SRC="$ROOT/cross-build/mlx"
DIST="$ROOT/Swift/.mlx-dist"
HOST_PYTHON="$ROOT/cross-build/$(uname -m)-apple-darwin/python.exe"
SDKS=("${@:-macosx iphoneos iphonesimulator xros xrsimulator}")
SDKS=(${SDKS[@]})

[ -x "$HOST_PYTHON" ] || { echo "run Swift/build.sh first" >&2; exit 1; }
[ -d "$SRC" ] || git clone --depth 1 --branch "$MLX_VERSION" https://github.com/ml-explore/mlx.git "$SRC"
"$HOST_PYTHON" "$ROOT/Swift/patch-mlx.py" "$SRC"

# Dependencies are fetched once and their sources shared between SDKs.
DEPS="$ROOT/cross-build/mlx-deps"
shared_deps() {
    SHARED_DEPS=()
    for dep in "$DEPS"/*; do
        if [ -d "$dep" ]; then
            SHARED_DEPS+=("-DFETCHCONTENT_SOURCE_DIR_$(basename "$dep" | tr a-z A-Z)=$dep")
        fi
    done
}
mkdir -p "$DEPS"
shared_deps
for SDK in "${SDKS[@]}"; do
    # The simulators get no Metal: MLX needs GPU features they lack.
    case "$SDK" in
        macosx)          SYSTEM=Darwin;   MIN=15.4; OS=macos; METAL=ON;  BUNDLE=cpython_mlx_metal_macos ;;
        iphoneos)        SYSTEM=iOS;      MIN=18.4; OS=ios;   METAL=ON;  BUNDLE=cpython_mlx_metal_ios ;;
        iphonesimulator) SYSTEM=iOS;      MIN=18.4; OS=ios;   METAL=OFF; BUNDLE= ;;
        xros)            SYSTEM=Darwin;   MIN=2.4;  OS=xros;  METAL=ON;  BUNDLE=cpython_mlx_metal_xros ;;
        xrsimulator)     SYSTEM=Darwin;   MIN=2.4;  OS=xros;  METAL=OFF; BUNDLE= ;;
        *) echo "unknown SDK $SDK" >&2; exit 1 ;;
    esac
    # CMake before 3.28 has no visionOS, and refuses its SDK as iOS: configure
    # it as macOS, whose version flag clang lets an explicit -target override.
    PLATFORM=(-DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN)
    case "$SDK" in
        xros)        TRIPLE=arm64-apple-xros$MIN ;;
        xrsimulator) TRIPLE=arm64-apple-xros$MIN-simulator ;;
        *)           TRIPLE= ;;
    esac
    if [ -n "$TRIPLE" ]; then
        TARGET="-target $TRIPLE -Wno-overriding-option"
        PLATFORM=(-DCMAKE_OSX_DEPLOYMENT_TARGET=15.4 -DCMAKE_C_FLAGS="$TARGET" -DCMAKE_CXX_FLAGS="$TARGET" -DMLX_NO_CPU_COMPILER=ON)
    fi
    PYDIST="$ROOT/Swift/.cpython-dist-$SDK"
    [ "$SDK" = macosx ] && PYDIST="$ROOT/Swift/.cpython-dist"
    [ -d "$PYDIST/include/python" ] || { echo "CPython is not staged for $SDK" >&2; exit 1; }

    BUILD="$ROOT/cross-build/mlx-$SDK"
    echo "=== $SDK"
    # MLX_METAL_JIT compiles most kernels on first use, which keeps the
    # metallib at 3.5 MB instead of 216.
    cmake -S "$SRC" -B "$BUILD" \
        -DCMAKE_SYSTEM_NAME=$SYSTEM -DCMAKE_OSX_SYSROOT="$(xcrun --sdk $SDK --show-sdk-path)" -DCMAKE_OSX_ARCHITECTURES=arm64 \
        "${PLATFORM[@]}" -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED_LIBS=OFF \
        -DMLX_BUILD_TESTS=OFF -DMLX_BUILD_EXAMPLES=OFF -DMLX_BUILD_BENCHMARKS=OFF \
        -DMLX_BUILD_PYTHON_BINDINGS=ON -DMLX_BUILD_PYTHON_STUBS=OFF -DMLX_USE_CCACHE=OFF \
        -DMLX_BUILD_METAL=$METAL -DMLX_METAL_JIT=ON -DMLX_METAL_SDK=$SDK \
        -DMLX_METAL_TARGET_OS="-mtargetos=$OS$MIN" -DMLX_SWIFTPM_BUNDLE="$BUNDLE" \
        -DPython_EXECUTABLE="$HOST_PYTHON" -DPython_INCLUDE_DIR="$PYDIST/include/python" \
        -DFETCHCONTENT_BASE_DIR="$ROOT/cross-build/mlx-deps-$SDK" ${SHARED_DEPS[@]+"${SHARED_DEPS[@]}"} \
        > "$BUILD.configure.log" 2>&1 || { tail -30 "$BUILD.configure.log"; exit 1; }
    cmake --build "$BUILD" --target core -j "$(sysctl -n hw.ncpu)" > "$BUILD.build.log" 2>&1 \
        || { grep -m10 -B2 -A5 "error" "$BUILD.build.log"; exit 1; }

    # mlx.core's objects plus every archive it links, as one archive.
    OUT="$DIST/$SDK"
    rm -rf "$OUT" && mkdir -p "$OUT/include"
    libtool -static -o "$OUT/libmlxcore.a" \
        "$BUILD"/python/src/CMakeFiles/core.dir/*.o \
        $(find "$BUILD" -name "*.a" -not -path "*/CMakeFiles/*")
    if [ "$METAL" = ON ]; then
        mkdir -p "$ROOT/Swift/Sources/mlx_metal_$OS"
        cp "$BUILD/mlx/backend/metal/kernels/mlx.metallib" "$ROOT/Swift/Sources/mlx_metal_$OS/default.metallib"
    fi
    echo "$SDK: $(du -h "$OUT/libmlxcore.a" | cut -f1)"

    for dep in "$ROOT/cross-build/mlx-deps-$SDK"/*-src; do
        name=$(basename "$dep" -src)
        if [ -d "$dep" ] && [ ! -d "$DEPS/$name" ]; then cp -R "$dep" "$DEPS/$name"; fi
    done
    shared_deps
done

# The Python half, as bytecode in a zip, by the stdlib's own script.
"$HOST_PYTHON" -I -B "$ROOT/Swift/stage_stdlib.py" \
    "$SRC/python" "$ROOT/Swift/Sources/mlx/modules.txt" "$ROOT/Swift/Sources/mlx/mlx.zip"

# Every staged slice, whichever ran this time.
rm -rf "$DIST/MLXCore.xcframework"
ARGS=()
for slice in "$DIST"/*/libmlxcore.a; do
    ARGS+=(-library "$slice" -headers "$(dirname "$slice")/include")
done
xcodebuild -create-xcframework "${ARGS[@]}" -output "$DIST/MLXCore.xcframework" > /dev/null
echo "staged $DIST/MLXCore.xcframework"
