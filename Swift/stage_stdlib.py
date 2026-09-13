"""Zips the stdlib modules listed in a manifest as bytecode, for zipimport:
`stage_stdlib.py <Lib dir> <manifest> <output zip>`.

Bytecode only: docstrings and signatures survive in it, so help() works;
only inspect.getsource and the source line under a stdlib traceback frame
are lost, for a third of the size.

Run by the StageStdlib plugin with the python built by build.sh, so the
bytecode matches the interpreter that will load it.
"""
import compileall
import py_compile
import shutil
import sys
import zipfile
from pathlib import Path

lib, manifest, output = (Path(argument) for argument in sys.argv[1:4])

names, prunes = [], []
for line in manifest.read_text().splitlines():
    for word in line.split("#")[0].split():
        (prunes if word.startswith("-") else names).append(word.lstrip("-"))

# Staged beside the output: the plugin sandbox allows writes only there.
staging = output.with_suffix(".staging")
shutil.rmtree(staging, ignore_errors=True)
staging.mkdir(parents=True)
try:
    for name in names:
        source = lib / name
        if source.is_dir():
            shutil.copytree(source, staging / name,
                            ignore=shutil.ignore_patterns("__pycache__"))
        elif source.with_suffix(".py").is_file():
            shutil.copy(source.with_suffix(".py"), staging)
        else:
            sys.exit(f"stage_stdlib: no module {name!r} in {lib}")
    for prune in prunes:
        target = staging / prune
        if target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()
        else:
            sys.exit(f"stage_stdlib: nothing to prune at {prune!r}")

    # Legacy layout (x.pyc beside x.py) is the one zipimport looks for;
    # unchecked hashes spare it a stat of the source on every import.
    if not compileall.compile_dir(staging, quiet=1, legacy=True,
                                  invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH):
        sys.exit("stage_stdlib: compile failed")

    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(staging.rglob("*.pyc")):
            archive.write(path, path.relative_to(staging))
finally:
    shutil.rmtree(staging, ignore_errors=True)
