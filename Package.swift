// swift-tools-version: 6.4
import PackageDescription

// What libpython itself needs, from the `Libs.private` line of
// Misc/python-embed.pc; Swift/build.sh prints the flags configure decided on,
// so compare the two if linking ever fails on a new platform.
let systemLibraries: [LinkerSetting] = [
    .linkedLibrary("iconv"),
    .linkedFramework("CoreFoundation"),
]

// A stdlib C module compiles the way CPython compiles a builtin: against both
// the public headers and Include/internal. Relative to Modules.
let moduleSettings: [CSetting] = [
    .define("Py_BUILD_CORE_BUILTIN"),
    .headerSearchPath("../Swift/Headers/python"),
    .headerSearchPath("../Swift/Headers/python/internal"),
]

let package = Package(
    name: "cpython",
    // 15.4 / 18.4 / 2.4 are what isolated `deinit` needs.
    platforms: [.macOS("15.4"), .iOS("18.4"), .visionOS("2.4")],
    products: [
        .library(name: "Python", targets: ["Python"]),
        // What a package of Python modules builds on, such as mlx or Pillow.
        .library(name: "PythonModules", targets: ["PythonModules"]),
        .executable(name: "pyrun", targets: ["pyrun"]),
        .executable(name: "pybench", targets: ["pybench"]),
    ],
    targets: [
        // libpython for each SDK, made by Swift/build-xcframework.sh.
        .binaryTarget(
            name: "PythonCore",
            url: "https://github.com/libswiftpy/cpython/releases/download/3.15.2-swiftpy.3/PythonCore.xcframework.zip",
            checksum: "cc9249444e3a4d05b7f33b915386e22521fae2e2acc6bbad4df2f190b1eb71b7"
        ),

        // The C API itself, imported through a module map.
        .systemLibrary(name: "CPython", path: "Swift/Sources/CPython"),

        // How a module describes itself. Its own target so that module targets
        // depend on this rather than on the interpreter wrapper — which also
        // lets `Python` depend on the modules it needs to start.
        .target(
            name: "PythonModules",
            dependencies: ["CPython", "PythonCore"],
            path: "Swift/Sources/PythonModules",
            linkerSettings: systemLibraries
        ),

        // The stdlib the interpreter cannot start without, one target per
        // module, named after the module it carries. SwiftPM packs each into
        // its own resource bundle, which Xcode embeds in the app — the only
        // place a sandboxed app can read them from. Staged by Swift/stage.sh.
        .target(
            name: "encodings",
            dependencies: ["PythonModules"],
            path: "Swift/Sources/encodings",
            resources: [.copy("encodings")]
        ),
        .target(
            name: "_apple_support",
            dependencies: ["PythonModules"],
            path: "Swift/Sources/_apple_support",
            resources: [.copy("_apple_support.py")]
        ),

        // The rest of the pure-Python stdlib the package ships, as one zip on
        // sys.path: zipimport loads the bytecode in it without a compile.
        // Swift/stage.sh makes it from Swift/Sources/stdlib/modules.txt.
        .target(
            name: "stdlib",
            dependencies: ["PythonModules"],
            path: "Swift/Sources/stdlib",
            exclude: ["modules.txt"],
            resources: [.copy("stdlib.zip")]
        ),

        // One C entry point per binding, so a Swift closure can be handed to
        // CPython as a function pointer of its own. See Bindings.swift.
        .target(
            name: "Cthunks",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["_swiftpy/thunks/thunks.c"],
            publicHeadersPath: "_swiftpy/thunks",
            cSettings: moduleSettings
        ),

        // A thin Swift face on top of it.
        .target(
            name: "Python",
            dependencies: ["CPython", "Cthunks", "PythonModules", "encodings", "_apple_support", "stdlib", "zlibmodule", "math", "_random", "_sha2", "_lsprof",
                           "_struct", "binascii", "_csv", "array", "cmathmodule", "_md5", "_sha1", "_sha3", "_blake2", "_sqlite3", "unicodedata", "pyexpat",
                           "select", "_socket", .target(name: "_posixsubprocess", condition: .when(platforms: [.macOS]))],
            path: "Swift/Sources/Python"
        ),

        // zlib: C only, so the compiled half and the Swift declaration are
        // two targets. zipimport needs it to read a compressed zip.
        .target(
            name: "Czlib",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["zlibmodule.c", "_swiftpy/zlib/shim.c"],
            publicHeadersPath: "_swiftpy/zlib",
            cSettings: moduleSettings,
            linkerSettings: [.linkedLibrary("z")]
        ),
        // Not `zlib`: Xcode would take that for the SDK's zlib module that
        // zlibmodule.c includes, and warn that Czlib is missing a dependency.
        .target(
            name: "zlibmodule",
            dependencies: ["PythonModules", "Czlib"],
            path: "Swift/Sources/zlibmodule"
        ),

        // Native dependencies of the bundled random module.
        .target(
            name: "Cmath",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["mathmodule.c", "mathintegermodule.c", "_swiftpy/math/shim.c"],
            publicHeadersPath: "_swiftpy/math",
            cSettings: moduleSettings
        ),
        .target(
            name: "math",
            dependencies: ["PythonModules", "Cmath"],
            path: "Swift/Sources/math"
        ),

        .target(
            name: "Crandom",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["_randommodule.c", "_swiftpy/_random/shim.c"],
            publicHeadersPath: "_swiftpy/_random",
            cSettings: moduleSettings
        ),
        .target(
            name: "_random",
            dependencies: ["PythonModules", "Crandom"],
            path: "Swift/Sources/_random"
        ),

        .target(
            name: "Csha2",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["sha2module.c", "_hacl/Hacl_Hash_SHA2.c", "_swiftpy/_sha2/shim.c"],
            publicHeadersPath: "_swiftpy/_sha2",
            cSettings: moduleSettings + [.headerSearchPath("_hacl"), .headerSearchPath("_hacl/include")]
        ),
        .target(
            name: "_sha2",
            dependencies: ["PythonModules", "Csha2"],
            path: "Swift/Sources/_sha2"
        ),

        // Native dependency of cProfile and profiling.tracing.
        .target(
            name: "Clsprof",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["_lsprof.c", "rotatingtree.c", "_swiftpy/_lsprof/shim.c"],
            publicHeadersPath: "_swiftpy/_lsprof",
            cSettings: moduleSettings
        ),
        .target(
            name: "_lsprof",
            dependencies: ["PythonModules", "Clsprof"],
            path: "Swift/Sources/_lsprof"
        ),

        // Optional C modules, each with its size once linked (code + data,
        // arm64) so the trade-off stays visible; drop one together with the
        // Python modules that import it. Small ones behind common imports
        // first: _struct 80 KB, binascii 90, _csv 60, array 110, cmath 60.
        .target(
            name: "Cstruct",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["_struct.c", "_swiftpy/_struct/shim.c"],
            publicHeadersPath: "_swiftpy/_struct",
            cSettings: moduleSettings
        ),
        .target(
            name: "_struct",
            dependencies: ["PythonModules", "Cstruct"],
            path: "Swift/Sources/_struct"
        ),

        .target(
            name: "Cbinascii",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["binascii.c", "_swiftpy/binascii/shim.c"],
            publicHeadersPath: "_swiftpy/binascii",
            cSettings: moduleSettings
        ),
        .target(
            name: "binascii",
            dependencies: ["PythonModules", "Cbinascii"],
            path: "Swift/Sources/binascii"
        ),

        .target(
            name: "Ccsv",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["_csv.c", "_swiftpy/_csv/shim.c"],
            publicHeadersPath: "_swiftpy/_csv",
            cSettings: moduleSettings
        ),
        .target(
            name: "_csv",
            dependencies: ["PythonModules", "Ccsv"],
            path: "Swift/Sources/_csv"
        ),

        .target(
            name: "Carray",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["arraymodule.c", "_swiftpy/array/shim.c"],
            publicHeadersPath: "_swiftpy/array",
            cSettings: moduleSettings
        ),
        .target(
            name: "array",
            dependencies: ["PythonModules", "Carray"],
            path: "Swift/Sources/array"
        ),

        .target(
            name: "Ccmath",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["cmathmodule.c", "_swiftpy/cmath/shim.c"],
            publicHeadersPath: "_swiftpy/cmath",
            cSettings: moduleSettings
        ),
        // Not `cmath`: that and the math module's `Cmath` collide on a
        // case-insensitive file system.
        .target(
            name: "cmathmodule",
            dependencies: ["PythonModules", "Ccmath"],
            path: "Swift/Sources/cmathmodule"
        ),

        // The rest of hashlib, so md5/sha1/sha3/blake2 work and not only sha2:
        // _md5 40 KB, _sha1 30, _sha3 120, _blake2 310.
        .target(
            name: "Cmd5",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["md5module.c", "_hacl/Hacl_Hash_MD5.c", "_swiftpy/_md5/shim.c"],
            publicHeadersPath: "_swiftpy/_md5",
            cSettings: moduleSettings + [.headerSearchPath("_hacl"), .headerSearchPath("_hacl/include")]
        ),
        .target(
            name: "_md5",
            dependencies: ["PythonModules", "Cmd5"],
            path: "Swift/Sources/_md5"
        ),

        .target(
            name: "Csha1",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["sha1module.c", "_hacl/Hacl_Hash_SHA1.c", "_swiftpy/_sha1/shim.c"],
            publicHeadersPath: "_swiftpy/_sha1",
            cSettings: moduleSettings + [.headerSearchPath("_hacl"), .headerSearchPath("_hacl/include")]
        ),
        .target(
            name: "_sha1",
            dependencies: ["PythonModules", "Csha1"],
            path: "Swift/Sources/_sha1"
        ),

        .target(
            name: "Csha3",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["sha3module.c", "_hacl/Hacl_Hash_SHA3.c", "_swiftpy/_sha3/shim.c"],
            publicHeadersPath: "_swiftpy/_sha3",
            cSettings: moduleSettings + [.headerSearchPath("_hacl"), .headerSearchPath("_hacl/include")]
        ),
        .target(
            name: "_sha3",
            dependencies: ["PythonModules", "Csha3"],
            path: "Swift/Sources/_sha3"
        ),

        .target(
            name: "Cblake2",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["blake2module.c", "_hacl/Hacl_Hash_Blake2s.c", "_hacl/Hacl_Hash_Blake2b.c", "_hacl/Lib_Memzero0.c", "_swiftpy/_blake2/shim.c"],
            publicHeadersPath: "_swiftpy/_blake2",
            cSettings: moduleSettings + [.headerSearchPath("_hacl"), .headerSearchPath("_hacl/include")]
        ),
        .target(
            name: "_blake2",
            dependencies: ["PythonModules", "Cblake2"],
            path: "Swift/Sources/_blake2"
        ),

        // sqlite3 against the system libsqlite3, so the module is 220 KB.
        .target(
            name: "Csqlite3",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["_sqlite/blob.c", "_sqlite/connection.c", "_sqlite/cursor.c", "_sqlite/microprotocols.c", "_sqlite/module.c", "_sqlite/prepare_protocol.c", "_sqlite/row.c", "_sqlite/statement.c", "_sqlite/util.c", "_swiftpy/_sqlite3/shim.c"],
            publicHeadersPath: "_swiftpy/_sqlite3",
            cSettings: moduleSettings + [.headerSearchPath("_sqlite")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "_sqlite3",
            dependencies: ["PythonModules", "Csqlite3"],
            path: "Swift/Sources/_sqlite3"
        ),

        // unicodedata carries the Unicode database: 740 KB, the largest here.
        .target(
            name: "Cunicodedata",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["unicodedata.c", "_swiftpy/unicodedata/shim.c"],
            publicHeadersPath: "_swiftpy/unicodedata",
            cSettings: moduleSettings
        ),
        .target(
            name: "unicodedata",
            dependencies: ["PythonModules", "Cunicodedata"],
            path: "Swift/Sources/unicodedata"
        ),

        // pyexpat bundles expat, 520 KB; xml.etree, xml.dom and plistlib parse
        // through it.
        .target(
            name: "Cpyexpat",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["pyexpat.c", "expat/xcs.c", "expat/xmlparse.c", "expat/xmlrole.c", "expat/xmltok.c", "_swiftpy/pyexpat/shim.c"],
            publicHeadersPath: "_swiftpy/pyexpat",
            cSettings: moduleSettings + [.headerSearchPath("expat")]
        ),
        .target(
            name: "pyexpat",
            dependencies: ["PythonModules", "Cpyexpat"],
            path: "Swift/Sources/pyexpat"
        ),

        // asyncio imports socket and selectors at module level: select 60 KB,
        // _socket 150. Only subprocess needs _posixsubprocess (30 KB), and only
        // where it can fork, so that one is macOS-only.
        .target(
            name: "Cselect",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["selectmodule.c", "_swiftpy/select/shim.c"],
            publicHeadersPath: "_swiftpy/select",
            cSettings: moduleSettings
        ),
        .target(
            name: "select",
            dependencies: ["PythonModules", "Cselect"],
            path: "Swift/Sources/select"
        ),

        .target(
            name: "Csocket",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["socketmodule.c", "_swiftpy/_socket/shim.c"],
            publicHeadersPath: "_swiftpy/_socket",
            cSettings: moduleSettings
        ),
        .target(
            name: "_socket",
            dependencies: ["PythonModules", "Csocket"],
            path: "Swift/Sources/_socket"
        ),

        .target(
            name: "Cposixsubprocess",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["_swiftpy/_posixsubprocess/shim.c"],
            publicHeadersPath: "_swiftpy/_posixsubprocess",
            cSettings: moduleSettings
        ),
        .target(
            name: "_posixsubprocess",
            dependencies: ["PythonModules", "Cposixsubprocess"],
            path: "Swift/Sources/_posixsubprocess"
        ),

        .executableTarget(name: "pyrun", dependencies: ["Python"], path: "Swift/Sources/pyrun"),
        .executableTarget(name: "pybench", dependencies: ["Python"], path: "Swift/Sources/pybench"),
        .testTarget(name: "PythonTests", dependencies: ["Python"], path: "Swift/Tests/PythonTests"),
    ]
)
