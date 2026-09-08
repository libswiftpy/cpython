# SwiftCPython

A minimal Swift package that embeds the CPython interpreter built from this
source tree. Plain Swift/C interop through a module map — no XCFramework, no
binary target.

The manifest sits at the repository root (`Package.swift`) so that a fork of
CPython *is* the Swift package; everything it adds lives here in `Swift/`.

| Path | What it is |
| --- | --- |
| `../Package.swift` | Package manifest: target paths, link flags |
| `Swift/build.sh` | Builds CPython, stages `.cpython-dist` (headers, `libpython.a`) and the stdlib resource |
| `Swift/Sources/Python/PythonHome/` | Minimal stdlib, staged by `build.sh`, shipped as a package resource |
| `Swift/Sources/CPython/module.modulemap` | Makes `Python.h` importable from Swift as `import CPython` |
| `Swift/Sources/Python/Python.swift` | Thin Swift wrapper: start, run, evaluate, GIL, errors |
| `Swift/Sources/Python/PythonOutput.swift` | Routes `sys.stdout`/`sys.stderr` to a Swift closure |
| `Swift/Sources/pyrun/main.swift` | Tiny command line interpreter using the wrapper |

## Use

```sh
./Swift/build.sh    # ~4 minutes; once, and after changing CPython itself
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

**Headers.** `build.sh` copies `Include/` plus the generated `pyconfig.h` into
`.cpython-dist/include/python`, so every `#include` inside `Python.h` resolves
relative to itself and no search paths are needed. The module map names that
one header by a path relative to itself. Both the header directory and the
staged `libpython.a` are unversioned, so a version bump in `patchlevel.h`
changes nothing outside `build.sh`.

**Linking.** `Package.swift` derives an absolute path to `.cpython-dist` from
`#filePath` and links `-lpython` plus the system libraries libpython needs,
chosen per platform with `.when(platforms:)`. CPython is configured
`--disable-shared`, so the interpreter is statically linked into the Swift
binary and there is nothing to ship alongside it but the stdlib below.
`build.sh` prints the flags configure actually decided on (`LIBS`,
`LINKFORSHARED`) and records them in `.cpython-dist/link-flags.txt`; compare
them with the manifest if linking fails on a platform not listed there.

**Stdlib.** Almost everything the interpreter needs at start-up (`os`, `io`,
`abc`, `codecs`, `site`, `stat`, `posixpath`, ...) is frozen into `libpython`.
The only package still imported from disk is `encodings`, so the staged
"stdlib" lives in `Sources/Python/PythonHome` and is seven files, 56 KB —
six for `encodings`, plus `_apple_support.py`, which iOS needs to route
`print()` through the system log:

```
encodings/__init__.py  aliases.py  _iconv_codecs.py  utf_8.py  latin_1.py  ascii.py
```

Add more of `Lib/` under `PythonHome/lib/python<X.Y>/` as your Python code
needs it; extension modules such as `_ssl` are built as `.so` files in the
CPython build tree and would go in `lib/python<X.Y>/lib-dynload/`.

**Home.** `Python.initialize()` defaults to the stdlib in the package's
resource bundle; pass `initialize(home:)` to point somewhere else.

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

The hook is a `PyCFunction` built in Swift and dropped into `__main__` as
`_swift_write`; a small Python class forwards `write()` to it. That is all
`sys.stdout` has to implement — no extension module needed. It does not catch
C code writing to file descriptor 1 directly; for that you would `dup2` a pipe
over `STDOUT_FILENO` instead.

## In an app bundle

Nothing to do: the minimal stdlib is a **resource of the `Python` target**, so
SwiftPM copies it into `SwiftCPython_Python.bundle` and Xcode embeds that in
`YourApp.app/Contents/Resources`. `Python.initialize()` resolves its home
through `Bundle.module`, which a sandboxed app can read — unlike the CPython
checkout the package was built from, which the App Sandbox blocks (the symptom
is a correct-looking path configuration followed by `Failed to import
encodings module`).

`libpython` itself needs no bundling; it is statically linked into the
executable.

Extension modules would be a different matter: `.so` files under
`lib-dynload/` have to be signed as part of the app, and iOS cannot `dlopen`
them at all.

## Platforms

Each platform is built out of tree, in `cross-build/<triple>`, and staged
separately; an iOS build refuses to run in a source tree that already holds a
build, which is why the macOS build moved out of tree too.

- **macOS (arm64)** — `./Swift/build.sh`. Built and tested against.
- **iOS** — `./Swift/build-ios.sh simulator` **and** `./Swift/build-ios.sh
  device`, after `build.sh`,
  which supplies the host python the cross-build needs. `configure` refuses a
  non-framework iOS build ("iOS builds must use --enable-framework"), but the
  framework is linked *from* `libpython3.16.a`, and that static archive is
  what gets staged — nothing to embed or sign, and no XCframework. Both
  destinations verified: an app runs on the simulator and links for device.
  See "Picking the iOS slice" below for the two build settings the app needs.
- **Linux** — expected to work; the manifest links
  `-ldl -lm -lutil -Xlinker -export-dynamic` there. Not verified.
- **tvOS, watchOS, Android** — same shape as iOS, not wired up.

### Picking the iOS slice

`build-ios.sh` stages the two slices side by side, in
`.cpython-dist-iphonesimulator` and `.cpython-dist-iphoneos`. Headers are
picked automatically — `Sources/CPython/shim.h` dispatches on
`TargetConditionals.h` — but the *library* cannot be: SwiftPM has no notion of
a simulator destination, and rejects build-setting references such as
`$(PLATFORM_NAME)` in target flags. (Autolinking it from the source with
`#pragma comment(lib, ...)` does not work either; Darwin clang ignores that
pragma.) This is the problem XCframeworks exist to solve.

So the app target chooses, with two SDK-conditional settings. In Build
Settings, add to **Library Search Paths** (the `+` on the row adds a
condition), replacing the path with your checkout:

| Condition | Value |
| --- | --- |
| Any iOS Simulator SDK | `<cpython>/Swift/.cpython-dist-iphonesimulator/lib` |
| Any iOS SDK | `<cpython>/Swift/.cpython-dist-iphoneos/lib` |

and to **Other Linker Flags**: `-lpython`.

Everything else iOS needs — `-liconv -ldl -lpthread -framework
CoreFoundation` — comes from the package. macOS needs none of this; it has
one slice, so the package links it directly.

*One architecture per slice.* Only arm64 is built, so build for an
Apple-silicon simulator (`-destination 'platform=iOS Simulator,name=…'`, or
`ONLY_ACTIVE_ARCH=YES`); `generic/platform=iOS Simulator` also wants x86_64.

Headers are selected per destination by `Sources/CPython/shim.h` through
`TargetConditionals.h`, so a project can build for macOS and iOS without
touching the package.

The package assumes a *host* build: `build.sh` configures and builds CPython
for the machine it runs on, and SwiftPM then links that.

Consuming a fork as a SwiftPM dependency works the same way, with one catch:
`.cpython-dist` is git-ignored, so a fresh checkout in `.build/checkouts` has
nothing to link against until `Swift/build.sh` has been run there. Commit the
staged directory (or a prebuilt `libpython.a`) if you want the fork to be
usable as a plain `.package(url:)` dependency.
