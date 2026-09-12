// swift-tools-version: 6.4
import Foundation
import PackageDescription

// The interpreter staged by Swift/build.sh. Absolute, because SwiftPM makes no
// promise about the working directory of compiler and linker invocations.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let distribution = URL(fileURLWithPath: packageDirectory)
    .appendingPathComponent("Swift/.cpython-dist")

// What libpython itself needs. These mirror the `Libs.private` line of
// Misc/python-embed.pc; Swift/build.sh prints the flags configure actually
// decided on, so compare the two if linking ever fails on a new platform.
// (LINKFORSHARED's `-stack_size` is left out: the linker rejects it for the
// test bundle. Add it to your own executable if you need deep recursion.)
let systemLibraries: [LinkerSetting] = [
    .unsafeFlags(
        ["-L\(distribution.path)/lib", "-lpython",
         "-liconv", "-ldl", "-framework", "CoreFoundation"],
        .when(platforms: [.macOS])
    ),
    // No -L/-lpython for iOS: SwiftPM cannot tell a simulator destination from
    // a device one, and rejects build-setting references like $(PLATFORM_NAME)
    // in target flags, so it cannot pick between the two staged slices. The
    // app supplies that with per-SDK LIBRARY_SEARCH_PATHS and -lpython in
    // OTHER_LDFLAGS; the rest of the flags do not vary, so they live here.
    // See Swift/README.md.
    .unsafeFlags(
        ["-liconv", "-ldl", "-lpthread", "-framework", "CoreFoundation"],
        .when(platforms: [.iOS, .visionOS])
    ),
    .unsafeFlags(
        ["-ldl", "-lm", "-lutil", "-Xlinker", "-export-dynamic"],
        .when(platforms: [.linux, .android])
    ),
]

// A stdlib C module compiles the way CPython compiles a builtin: against both
// the public headers and Include/internal.
let moduleSettings: [CSetting] = [
    .define("Py_BUILD_CORE_BUILTIN"),
    .unsafeFlags([
        "-I\(distribution.path)/include/python",
        "-I\(distribution.path)/include/python/internal",
    ], .when(platforms: [.macOS])),
    .unsafeFlags([
        "-I\(packageDirectory)/Swift/.cpython-dist-iphoneos/include/python",
        "-I\(packageDirectory)/Swift/.cpython-dist-iphoneos/include/python/internal",
    ], .when(platforms: [.iOS])),
    .unsafeFlags([
        "-I\(packageDirectory)/Swift/.cpython-dist-xros/include/python",
        "-I\(packageDirectory)/Swift/.cpython-dist-xros/include/python/internal",
    ], .when(platforms: [.visionOS])),
]

let package = Package(
    name: "cpython",
    // 15.4 / 18.4 / 2.4 are what isolated `deinit` needs.
    platforms: [.macOS("15.4"), .iOS("18.4"), .visionOS("2.4")],
    products: [
        .library(name: "Python", targets: ["Python"]),
        .executable(name: "pyrun", targets: ["pyrun"]),
    ],
    targets: [
        // The C API itself, imported through a module map.
        .systemLibrary(name: "CPython", path: "Swift/Sources/CPython"),

        // How a module describes itself. Its own target so that module targets
        // depend on this rather than on the interpreter wrapper — which also
        // lets `Python` depend on the modules it needs to start.
        .target(
            name: "PythonModules",
            dependencies: ["CPython"],
            path: "Swift/Sources/PythonModules"
        ),

        // The stdlib the interpreter cannot start without, one target per
        // module, named after the module it carries. SwiftPM packs each into
        // its own resource bundle, which Xcode embeds in the app — the only
        // place a sandboxed app can read them from. Staged by Swift/build.sh.
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

        // The rest of the pure-Python stdlib the package ships, in one bundle
        // rather than one per module: the list is meant to grow, and the plan
        // is a zip on sys.path once it does.
        .target(
            name: "stdlib",
            dependencies: ["PythonModules"],
            path: "Swift/Sources/stdlib",
            resources: [.copy("stdlib")]
        ),

        // A thin Swift face on top of it.
        .target(
            name: "Python",
            dependencies: ["CPython", "PythonModules", "encodings", "_apple_support", "stdlib", "zlib", "math", "_random", "_sha2", "_lsprof"],
            path: "Swift/Sources/Python",
            linkerSettings: systemLibraries
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
        .target(
            name: "zlib",
            dependencies: ["PythonModules", "Czlib"],
            path: "Swift/Sources/zlib"
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

        .executableTarget(name: "pyrun", dependencies: ["Python"], path: "Swift/Sources/pyrun"),
        .testTarget(name: "PythonTests", dependencies: ["Python"], path: "Swift/Tests/PythonTests"),
    ]
)
