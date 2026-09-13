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
        --without-doc-strings \
        --without-remote-debug  # sys.remote_exec: task_for_pid, useless embedded
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

# The pure-Python stdlib the package ships. functools and everything it
# reaches at import time, plus what `collections` defers with 3.15's lazy
# import -- copy and heapq are needed the moment Counter.most_common or
# OrderedDict.copy is called. None of these needs a C module of its own:
# heapq falls back to its Python path when _heapq is absent.
# inspect and what it imports come next: rlcompleter and help() read
# signatures through it. re and tokenize are its lazy imports, left out.
# datetime uses the _datetime builtin already linked into libpython. cProfile
# and profiling.tracing use the _lsprof target compiled by SwiftPM.
STDLIB_MODULES=(
    functools operator types reprlib keyword datetime random bisect pkgutil
    copy copyreg weakref _weakrefset heapq
    inspect enum dis ast _ast_unparse _colorize dataclasses contextlib annotationlib opcode token tokenize _opcode_metadata
    traceback linecache textwrap codeop warnings _py_warnings __future__
    typing cProfile pstats numbers fractions
)
# json falls back to its Python scanner without _json; re needs only _sre.
STDLIB_PACKAGES=(collections importlib json re profiling pathlib)

# Everything below is optional: pure Python that only costs the bytes listed
# (uncompressed, as staged; 2.3 MB in all), grouped so a group can be dropped
# as one when size matters more than reach. The C modules some of them need
# are SwiftPM targets in Package.swift, with their sizes noted there.
STDLIB_MODULES+=(
    # text and numbers, 480 KB: decimal is 230 KB of that (_pydecimal; there
    # is no _decimal) and statistics needs it; string is the package below.
    timeit statistics decimal _pydecimal _pylong contextvars pprint difflib
    # files, 350 KB with the zoneinfo and sysconfig packages below: zoneinfo
    # reads the system tz database (PYTHONTZPATH, set in Python.swift);
    # tempfile and shutil back zipfile and tarfile.
    shutil glob fnmatch tempfile calendar gettext locale
    # formats, 1.3 MB with the packages below -- xml is 340 KB, zipfile 110,
    # html 110: base64 and zipfile need binascii and struct, csv needs _csv,
    # plistlib and xml need pyexpat, gzip the compression package.
    base64 struct csv pickle _compat_pickle tarfile gzip plistlib
    configparser ipaddress mimetypes shlex graphlib colorsys _strptime _markupbase
    # secrets, 70 KB: hashlib is complete with the _md5/_sha1/_sha3/_blake2
    # targets; hmac and secrets build on it.
    hashlib hmac secrets uuid
    # scripts and tests, 280 KB with unittest below (170 KB): argparse for
    # CLI-style code; unittest needs signal. doctest would need pdb: left out.
    argparse signal
    # threads, 260 KB with logging (80 KB) and concurrent (100 KB) below:
    # nothing runs in parallel (the GIL never moves), but logging, asyncio and
    # concurrent.futures import these.
    threading _threading_local queue
)
STDLIB_PACKAGES+=(
    string urllib html tomllib zoneinfo sysconfig zipfile sqlite3 xml
    unittest logging concurrent compression
)
for module in "${STDLIB_MODULES[@]}"; do
    cp "$ROOT/Lib/$module.py" "$STDLIB_DIR/"
done
for package in "${STDLIB_PACKAGES[@]}"; do
    cp -R "$ROOT/Lib/$package" "$STDLIB_DIR/"
done
# The `python -m json.tool` CLI, which drags argparse in.
rm -f "$STDLIB_DIR/json/tool.py"
# What needs sockets, subinterpreters or a C codec that is not built, and
# CLIs: urllib keeps only its parsing half (requests are a Swift binding),
# logging its core, compression only gzip and zlib, unittest drops mock
# (~120 KB).
rm -rf "$STDLIB_DIR/urllib/request.py" "$STDLIB_DIR/urllib/response.py" \
       "$STDLIB_DIR/urllib/robotparser.py" "$STDLIB_DIR/urllib/error.py" \
       "$STDLIB_DIR/logging/config.py" "$STDLIB_DIR/logging/handlers.py" \
       "$STDLIB_DIR/concurrent/interpreters" \
       "$STDLIB_DIR/unittest/mock.py" "$STDLIB_DIR/unittest/__main__.py" \
       "$STDLIB_DIR/zipfile/__main__.py" \
       "$STDLIB_DIR/tomllib/__main__.py" "$STDLIB_DIR/tomllib/mypy.ini" \
       "$STDLIB_DIR/sysconfig/__main__.py" \
       "$STDLIB_DIR/compression/bz2.py" "$STDLIB_DIR/compression/lzma.py" "$STDLIB_DIR/compression/zstd"
# The sampling profiler needs a second process and ships ~1 MB of vendored
# web assets; only profiling.tracing (cProfile) is usable embedded.
rm -rf "$STDLIB_DIR/profiling/sampling"

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
