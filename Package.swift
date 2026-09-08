// swift-tools-version: 6.0
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
        .when(platforms: [.iOS])
    ),
    .unsafeFlags(
        ["-ldl", "-lm", "-lutil", "-Xlinker", "-export-dynamic"],
        .when(platforms: [.linux, .android])
    ),
]

let package = Package(
    name: "SwiftCPython",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Python", targets: ["Python"]),
        .executable(name: "pyrun", targets: ["pyrun"]),
    ],
    targets: [
        // The C API itself, imported through a module map.
        .systemLibrary(name: "CPython", path: "Swift/Sources/CPython"),

        // A thin Swift face on top of it.
        .target(
            name: "Python",
            dependencies: ["CPython"],
            path: "Swift/Sources/Python",
            // SwiftPM copies this into SwiftCPython_Python.bundle, which Xcode
            // in turn embeds in the app — the only way a sandboxed app can
            // reach the stdlib. Staged by Swift/build.sh.
            resources: [.copy("PythonHome")],
            linkerSettings: systemLibraries
        ),

        .executableTarget(name: "pyrun", dependencies: ["Python"], path: "Swift/Sources/pyrun"),
        .testTarget(name: "PythonTests", dependencies: ["Python"], path: "Swift/Tests/PythonTests"),
    ]
)
