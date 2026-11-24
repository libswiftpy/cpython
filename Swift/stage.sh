#!/bin/bash
# Refreshes what the packages ship from Lib: encodings, _apple_support and the
# stdlib's bytecode, and Pillow's and mlx's where they're checked out beside
# this one. All committed, so a fresh checkout builds without a Python. Run it
# after a change to Lib or a modules.txt; build.sh does too.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="$ROOT/cross-build/$(uname -m)-apple-darwin/python.exe"
[ -x "$PYTHON" ] || { echo "run Swift/build.sh first: the bytecode comes from its python" >&2; exit 1; }

ENCODINGS_DIR="$ROOT/Swift/Sources/encodings/encodings"
rm -rf "$ENCODINGS_DIR"
mkdir -p "$ENCODINGS_DIR"

# What the interpreter imports from disk while starting; the rest it needs then
# is frozen into libpython. After those, what a text app meets in the wild,
# 140 KB: UTF-16/32 and BOM-prefixed UTF-8 for files, cp1252 and mac_roman for
# legacy text, cp437 for zip entry names, idna for URLs, the escape codecs for
# str methods. CJK code pages need C codecs and stay out.
for module in __init__ aliases utf_8 latin_1 ascii \
    utf_8_sig utf_16 utf_16_be utf_16_le utf_32 utf_32_be utf_32_le \
    cp1252 mac_roman charmap cp437 idna punycode unicode_escape raw_unicode_escape; do
    cp "$ROOT/Lib/encodings/$module.py" "$ENCODINGS_DIR/"
done
# 3.16 and later only; `encodings` does not reach for it before that.
if [ -f "$ROOT/Lib/encodings/_iconv_codecs.py" ]; then
    cp "$ROOT/Lib/encodings/_iconv_codecs.py" "$ENCODINGS_DIR/"
fi

# iOS routes stdout and stderr through the system log, via this module.
cp "$ROOT/Lib/_apple_support.py" "$ROOT/Swift/Sources/_apple_support/"

# stage <package> <target>: zips what the target's modules.txt lists, from the
# package's Lib or the directory a `# source: ` line names.
stage() {
    local target="$1/Swift/Sources/$2"
    local source
    source=$(sed -n 's/^# source: //p' "$target/modules.txt" | head -1)
    "$PYTHON" -I -B "$ROOT/Swift/stage_stdlib.py" "$1/${source:-Lib}" "$target/modules.txt" "$target/$2.zip"
    echo "staged $2.zip ($(du -h "$target/$2.zip" | cut -f1 | xargs))"
}
stage "$ROOT" stdlib
for package in "Pillow PIL" "mlx mlx"; do
    read -r name target <<< "$package"
    if [ -f "$ROOT/../$name/Swift/Sources/$target/modules.txt" ]; then stage "$ROOT/../$name" "$target"; fi
done
