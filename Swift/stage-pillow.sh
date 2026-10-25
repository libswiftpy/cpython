#!/bin/bash
# Stages Pillow and the libraries it is built with, as sources SwiftPM compiles
# for whichever platform is being built: Modules/_pillow/{Pillow,jpeg,freetype,
# webp} and the PIL package as Swift/Sources/PIL/PIL.zip.
#
# JPEG through libjpeg-turbo (without its SIMD code), PNG through zlib, fonts
# through FreeType, and WebP. TIFF, JPEG 2000, colour management and complex
# text layout are left out; Pillow reports them as unavailable.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/cross-build/pillow"
OUT="$ROOT/Modules/_pillow"

fetch() {  # repository, tag, directory
    [ -d "$SRC/$3" ] || git clone -q --depth 1 --branch "$2" "https://github.com/$1.git" "$SRC/$3"
}
mkdir -p "$SRC"
fetch python-pillow/Pillow 13.0.0 Pillow
fetch libjpeg-turbo/libjpeg-turbo 3.1.4.1 libjpeg-turbo
fetch freetype/freetype VER-2-15-0 freetype
fetch webmproject/libwebp v1.6.0 libwebp

rm -rf "$OUT" "$ROOT/Swift/Sources/PIL/PIL"
mkdir -p "$OUT"

# Pillow's C half; its build script compiles every file of libImaging.
mkdir -p "$OUT/Pillow/src"
cp -R "$SRC/Pillow/src/libImaging" "$SRC/Pillow/src/thirdparty" "$OUT/Pillow/src/"
cp "$SRC/Pillow/src/"{_imaging,decode,encode,map,display,outline,path,_imagingft,_webp,_imagingmath,_imagingmorph}.c "$OUT/Pillow/src/"
rm -rf "$OUT/Pillow/src/thirdparty/raqm" "$OUT/Pillow/src/thirdparty/fribidi-shim"
# Each module is its own library upstream, and _webp repeats _imaging's GIL
# helpers; linked together, the copies collide.
python3 - "$OUT/Pillow/src/_webp.c" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
for name, body in [("Enter", "*cookie = (PyThreadState *)PyEval_SaveThread();"),
                   ("Leave", "PyEval_RestoreThread((PyThreadState *)*cookie);")]:
    definition = f"void\nImagingSection{name}(ImagingSectionCookie *cookie) {{\n    {body}\n}}\n"
    if definition not in text:
        sys.exit(f"stage-pillow: _webp.c no longer defines ImagingSection{name} as expected")
    text = text.replace(definition, "")
open(path, "w").write(text)
PY
cp "$SRC/Pillow/LICENSE" "$OUT/Pillow/"

# libjpeg-turbo: the headers CMake would generate, for 64-bit Apple platforms.
JPEG="$OUT/jpeg"
mkdir -p "$JPEG/include"
cp -R "$SRC/libjpeg-turbo/src" "$JPEG/src"
cp "$SRC/libjpeg-turbo/LICENSE.md" "$SRC/libjpeg-turbo/README.ijg" "$JPEG/"
sed -e 's/@JPEG_LIB_VERSION@/62/' -e 's/@VERSION@/3.1.4.1/' \
    -e 's/@LIBJPEG_TURBO_VERSION_NUMBER@/3001004/' \
    -e 's/#cmakedefine C_ARITH_CODING_SUPPORTED 1/#define C_ARITH_CODING_SUPPORTED 1/' \
    -e 's/#cmakedefine D_ARITH_CODING_SUPPORTED 1/#define D_ARITH_CODING_SUPPORTED 1/' \
    -e 's|#cmakedefine \(.*\)|/* #undef \1 */|' \
    "$JPEG/src/jconfig.h.in" > "$JPEG/src/jconfig.h"
sed -e 's/@BUILD@/swiftpy/' -e 's/@HIDDEN@/__attribute__((visibility("hidden")))/' \
    -e 's/@INLINE@/__inline__ __attribute__((always_inline))/' -e 's/@THREAD_LOCAL@/__thread/' \
    -e 's/@CMAKE_PROJECT_NAME@/libjpeg-turbo/' -e 's/@VERSION@/3.1.4.1/' -e 's/@SIZE_T@/8/' \
    -e 's/#cmakedefine HAVE_BUILTIN_CTZL/#define HAVE_BUILTIN_CTZL/' \
    -e 's/#cmakedefine C_ARITH_CODING_SUPPORTED 1/#define C_ARITH_CODING_SUPPORTED 1/' \
    -e 's/#cmakedefine D_ARITH_CODING_SUPPORTED 1/#define D_ARITH_CODING_SUPPORTED 1/' \
    -e 's|#cmakedefine \(.*\)|/* #undef \1 */|' \
    "$JPEG/src/jconfigint.h.in" > "$JPEG/src/jconfigint.h"
sed -e 's/@COPYRIGHT_YEAR@/1991-2026/' "$JPEG/src/jversion.h.in" > "$JPEG/src/jversion.h"
cp "$JPEG/src/"{jpeglib.h,jmorecfg.h,jerror.h,jconfig.h} "$JPEG/include/"
# jpeglib.h needs FILE and size_t declared first, so it is no module alone.
printf '#include <stddef.h>\n#include <stdio.h>\n#include "jpeglib.h"\n' > "$JPEG/include/Cjpeg.h"
printf 'module Cjpeg {\n    header "Cjpeg.h"\n    export *\n}\n' > "$JPEG/include/module.modulemap"

# FreeType with its default modules and options: its own zlib copy, no PNG.
mkdir -p "$OUT/freetype"
cp -R "$SRC/freetype/src" "$SRC/freetype/include" "$OUT/freetype/"
cp "$SRC/freetype/LICENSE.TXT" "$OUT/freetype/"
# Only ft2build.h: the rest is included through its macros, internal headers too.
printf 'module Cfreetype {\n    header "ft2build.h"\n    export *\n}\n' > "$OUT/freetype/include/module.modulemap"

# libwebp; dependents include <webp/...>, its own sources "src/...".
mkdir -p "$OUT/webp/include"
cp -R "$SRC/libwebp/src" "$SRC/libwebp/sharpyuv" "$OUT/webp/"
cp -R "$SRC/libwebp/src/webp" "$OUT/webp/include/"
cp "$SRC/libwebp/COPYING" "$SRC/libwebp/PATENTS" "$OUT/webp/"

# The Python half, as bytecode in a zip, by the stdlib's own script.
"$ROOT/cross-build/$(uname -m)-apple-darwin/python.exe" -I -B "$ROOT/Swift/stage_stdlib.py" \
    "$SRC/Pillow/src" "$ROOT/Swift/Sources/PIL/modules.txt" "$ROOT/Swift/Sources/PIL/PIL.zip"

echo "staged Pillow ($(du -sh "$OUT" | cut -f1) of sources, $(du -sh "$ROOT/Swift/Sources/PIL/PIL.zip" | cut -f1) of Python)"
