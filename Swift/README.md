# cpython, as a Swift package

A minimal Swift package that embeds the CPython interpreter built from this
source tree. Plain Swift/C interop through a module map; `libpython` itself is a
binary target, and the rest builds from source, so a fresh checkout needs no
script run first.

The manifest sits at the repository root (`Package.swift`) so that a fork of
CPython *is* the Swift package; everything it adds lives here in `Swift/`.

| Path | What it is |
| --- | --- |
| `../Package.swift` | Package manifest: target paths, link flags |
| `Swift/build-xcframework.sh` | Builds libpython for every Apple SDK, packs `PythonCore.xcframework` and makes `Swift/Headers` |
| `Swift/stage.sh` | Refreshes the parts of `Lib` the package ships, all committed |
| `Swift/build.sh`, `build-ios.sh`, `build-visionos.sh` | CPython's own builds, which `build-xcframework.sh` runs |
| `Swift/Headers/python` | CPython's headers, with a `pyconfig.h` that picks the SDK's |
| `Swift/Sources/stdlib/modules.txt` | The rest of the pure-Python stdlib to ship, with what each group costs |
| `Swift/Sources/encodings`, `Swift/Sources/_apple_support` | What the interpreter imports while starting |
| `Swift/Sources/CPython/module.modulemap` | Makes `Python.h` importable from Swift as `import CPython` |
| `Swift/Sources/Python/Python.swift` | Thin Swift wrapper: start, run, evaluate, GIL, errors |
| `Swift/Sources/Python/PythonModule.swift` | How a target declares its builtins and search paths |
| `Swift/Sources/Python/PythonOutput.swift` | Routes `sys.stdout`/`sys.stderr` to a Swift closure |
| `Swift/Sources/pyrun/main.swift` | Tiny command line interpreter using the wrapper |

## Use

```sh
swift test
swift run pyrun "print('hello from', __import__('sys').version)"
```

```swift
import Python

try Python.initialize()
try Python.run("xs = [n * n for n in range(5)]")
print(try Python.evaluate("sum(xs)"))   // 30
Python.finalize()
```

Anything the wrapper does not cover is one `import CPython` away — the whole C
API is visible to Swift.

## How it hangs together

**Headers.** `Swift/Headers/python` is a copy of `Include/` with every SDK's
generated `pyconfig.h`, under a name of its own. Only those differ by SDK, so its
`pyconfig.h` includes the right one by `TargetConditionals`. They aren't in
`Include/`, where CPython's own build would find them before its own.

**Linking.** `libpython` is `PythonCore`, a binary target holding a static
library per SDK, so SwiftPM and Xcode pick the slice and the interpreter ends up
in the binary. `build.sh` prints the flags configure decided on and records them
in `.cpython-dist/link-flags.txt`; compare them with the manifest if linking
fails.

**Stdlib.** Almost everything the interpreter needs at start-up (`os`, `io`,
`abc`, `codecs`, `site`, `stat`, `posixpath`, ...) is frozen into `libpython`.
Only two things are still imported from disk, and each is its own target:
`encodings` (six files, 44 KB) and `_apple_support.py`, which iOS needs to
route `print()` through the system log.

```
encodings/__init__.py  aliases.py  _iconv_codecs.py  utf_8.py  latin_1.py  ascii.py
```

A further module follows the same shape: a target with the `.py` files as
resources, declared as a ``PythonModule`` whose `searchPaths` point at its
bundle, and passed to `Python.initialize(modules:)`. A module with a C half
adds a second target compiling that `.c` from `Modules/` — SwiftPM builds it
for whatever destination is being targeted, which is what iOS needs, since it
cannot `dlopen` the `.so` files a normal CPython build produces — and declares
it in `builtins`, which `initialize` puts in the inittab.

**GIL.** `initialize()` releases the lock it is handed, and every call in goes
through `Python.withGIL`, so the interpreter can be driven from any thread.

## Capturing output

`print()` goes to `sys.stdout`, which on iOS is the system log and in a GUI app
is nowhere useful. `redirectOutput(to:)` points both streams at a Swift
closure:

```swift
try Python.initialize()
try Python.redirectOutput { text in
    transcript.append(text)          // any Swift code you like
}
try Python.run("print('hello')")     // -> "hello" then "\n"
```

Text arrives in the chunks Python writes, so one `print()` is usually two
calls: the value, then the newline. Tracebacks come through the same way,
since they are written to `sys.stderr`. Pass `nil` to restore
`sys.__stdout__`/`sys.__stderr__`.

The hook is a `PyCFunction` built in Swift, kept in a namespace of its own
as `_swift_write`; a small Python class forwards `write()` to it. It stays out
of `__main__` so clearing that does not take `print` with it. That is all
`sys.stdout` has to implement — no extension module needed. It does not catch
C code writing to file descriptor 1 directly; for that you would `dup2` a pipe
over `STDOUT_FILENO` instead.

## In an app bundle

Nothing to do: the bundled stdlib is a **resource of a Swift target** --
`encodings` and `_apple_support` have one each, because the interpreter needs
them while starting, and everything else is `stdlib.zip` in the `stdlib`
target: bytecode only, made by `stage.sh` from `modules.txt`, loaded by `zipimport` without a compile or an unzip. SwiftPM
packs them into `cpython_*.bundle`s, and Xcode embeds those in
`YourApp.app/Contents/Resources`. `Python.initialize()` puts their
`Bundle.module` paths on `sys.path`, which a sandboxed app can read —
unlike the CPython checkout the package was built from, which the App Sandbox
blocks (the symptom is a correct-looking path configuration followed by
`Failed to import encodings module`).

There is no `PYTHONHOME`: a home is a single directory tree, which cannot
describe one bundle per module. `initialize` sets `config.module_search_paths`
outright instead — `encodings` has to be importable before initialization
finishes, which is too early to append to `sys.path`.

`libpython` itself needs no bundling; it is statically linked into the
executable.

Extension modules would be a different matter: `.so` files under
`lib-dynload/` have to be signed as part of the app, and iOS cannot `dlopen`
them at all.

## Third-party modules

Packages of their own, forks of `Pillow` (about 7 MB) and `mlx` (about 16 MB),
depend on the `PythonModules` product and declare a `PythonModule`. An app
that wants one sets it before the interpreter starts:

```swift
PyRuntime.additionalModules = [.pil, .mlx]
```

Their Python half is a committed zip of bytecode too, which `stage.sh` refreshes
where they're checked out beside this package.

## What to run after a change

| Changed | Run |
| --- | --- |
| Swift, `Modules/*.c` of a target, `Modules/_swiftpy` | nothing |
| `Lib`, a `modules.txt`, Pillow's or mlx's Python | `Swift/stage.sh` |
| `Include`, `Objects`, `Parser`, `Python`, a module inside libpython, a new CPython version | `Swift/build-xcframework.sh`, then a release |

`StagedStdlibTests` fails where `stage.sh` was forgotten. `stage.sh` needs the
host python in `cross-build`, so run `Swift/build.sh` once (about 4 minutes) on a
machine that edits `Lib`.

For a release, upload `Swift/.cpython-dist-xcframework/PythonCore.xcframework.zip`
and put its URL and checksum in `Package.swift`. To try a build first, point the
binary target at the folder next to it: `.binaryTarget(name: "PythonCore", path:
"Swift/.cpython-dist-xcframework/PythonCore.xcframework")`.

## Platforms

macOS, iOS, visionOS and their simulators, arm64 only, so build for an
Apple-silicon simulator. Each is built out of tree, in `cross-build/<triple>`, as
an iOS build refuses a source tree that already holds one. `configure` refuses a
non-framework iOS build ("iOS builds must use --enable-framework"), but the
framework is linked *from* `libpython.a`, which is what's kept.
